//
// PCILeech FPGA.
//
// R1 requester tracking: entry table, timers and sweep.
// Contract: PCILeechFWGenerator docs/development/MSIX_REQUESTER_CONTRACT.md
// sections 4 (entry), 6 (lifecycle), 8 (timer/control), 9 (Transactions Pending).
//
// One entry per internal tag. FREE -> RESERVED on admit, RESERVED -> ISSUED at the
// accepted tlast (timestamp and the live timeout code/Disable latched here), and
// ISSUED/QUARANTINED -> FREE on a final or terminal completion. A sweep visits one
// entry per cycle: an ISSUED entry whose latched limit has elapsed, with neither the
// latched nor the live Disable set, becomes QUARANTINED and raises a timeout event; a
// QUARANTINED entry is released after its drain interval. A retire for the entry the
// sweep is visiting wins over its expiry in the same cycle. Issue and quarantine times
// are kept separately; elapsed time is modular, so an entry held ISSUED by the live Disable for more than 2^W ticks can
// expire up to one counter period late after Disable clears, never early.
//
// FLR (contract section 6): every ISSUED entry becomes QUARANTINED at once and drains
// Q after the FLR, using its latched code (64 s if Disable was latched); no timeout
// event is raised. Every RESERVED entry is marked doomed and stays RESERVED until its
// packet is resolved: a discard (release) frees it, and an accepted tlast sends it
// straight to QUARANTINED, draining Q after that issue. The drain start of a
// QUARANTINED entry is therefore its issue time (quarantined at issue), the last FLR
// time (quarantined by an FLR), or the sweep's quarantine time. A second FLR moves the
// shared FLR time forward, which can only delay the release of entries quarantined by
// the first one.
//
`timescale 1ns / 1ps
`include "pcileech_req_defs.svh"

module pcileech_req_table #(
    parameter longint CLK_PCIE_HZ = 62_500_000,
    parameter int     TICK_CYCLES = 64,
    parameter int     W           = 28
) (
    input           clk,
    input           rst,            // link session abort: every entry -> FREE
    input           flr,            // cfg_received_func_lvl_rst, one-cycle event
    input  [3:0]    ctl_code,       // cfg_dcommand2[3:0], one-cycle register in pcileech_pcie_a7
    input           ctl_disable,    // cfg_dcommand2[4], one-cycle register in pcileech_pcie_a7
    // admit (req_gate): FREE -> RESERVED
    input           adm_valid,
    input  [7:0]    adm_tag,
    input  [7:0]    adm_host_tag,
    input  [12:0]   adm_bc,
    input  [6:0]    adm_la,
    input  [2:0]    adm_tc,
    input  [1:0]    adm_attr,
    // issue (req_tx_obs): RESERVED -> ISSUED at accepted tlast
    input           iss_valid,
    input  [7:0]    iss_tag,
    // release (req_gate): RESERVED -> FREE when its packet is discarded
    input           rel_valid,
    input  [7:0]    rel_tag,
    // lookup (req_rx_cpl), combinational
    input  [7:0]    lk_tag,
    output [1:0]    lk_state,
    output [7:0]    lk_host_tag,
    output          lk_superseded,
    output [12:0]   lk_remaining,
    output [6:0]    lk_next_la,
    output [2:0]    lk_tc,
    output [1:0]    lk_attr,
    // update (req_rx_cpl): progress, or retire -> FREE
    input           up_valid,
    input  [7:0]    up_tag,
    input           up_retire,
    input  [12:0]   up_remaining,
    input  [6:0]    up_next_la,
    // status
    output [255:0]  free,
    output reg      to_valid,       // timeout event (ISSUED -> QUARANTINED)
    output reg [7:0] to_tag,
    output reg [8:0] n_reserved,
    output reg [8:0] n_issued,
    output reg [8:0] n_quarantined,
    output          trn_pending,    // RESERVED or ISSUED exist (QUARANTINED excluded)
    output reg      err_bypass,     // sticky: issue for a tag that is not RESERVED
    output reg      err_release     // sticky: release for a tag that is not RESERVED
);
    // ---- entry storage ----------------------------------------------------------------------
    // Per-entry control state lives in flops; every wide field lives in distributed RAM
    // with exactly one writer and asynchronous reads, so no field needs a per-bit
    // multi-port write mux (an all-flop table is ~42k LUTs on the xc7a100t).
    reg [1:0]   st  [0:255];        // flops: written by admit, issue, update, sweep, reset
    reg         sup [0:255];        // flops: superseded
    reg         lvt [0:255];        // flops: 1 = remaining/next LA newest in the update bank
    reg         fl  [0:255];        // flops: RESERVED or ISSUED at an FLR since admission

    reg [12:0]  meta  [0:255];      // RAM, admit:  {host_tag, tc, attr}
    reg [7:0]   hostc [0:255];      // RAM, admit:  host_tag copy for the supersede read
    reg [19:0]  rem_a [0:255];      // RAM, admit:  {remaining, next LA}
    reg [19:0]  rem_u [0:255];      // RAM, update: {remaining, next LA}
    reg [W+5:0] issr  [0:255];      // RAM, issue:  {quarantined at issue, issue time, code, disable}
    reg [W-1:0] tqr   [0:255];      // RAM, sweep:  quarantine time
    reg [7:0]   rev   [0:255];      // RAM, admit:  host tag -> newest internal tag

    integer i;
    initial for (i = 0; i < 256; i = i + 1) begin
        meta[i] = '0; hostc[i] = '0; rem_a[i] = '0; rem_u[i] = '0;
        issr[i] = '0; tqr[i] = '0; rev[i] = '0;
    end

    genvar g;
    generate for (g = 0; g < 256; g = g + 1) begin : g_free
        assign free[g] = (st[g] == `REQ_ST_FREE);
    end endgenerate

    wire [12:0] lk_meta = meta[lk_tag];
    wire [19:0] lk_rem  = lvt[lk_tag] ? rem_u[lk_tag] : rem_a[lk_tag];
    assign lk_state      = st[lk_tag];
    assign lk_host_tag   = lk_meta[12:5];
    assign lk_remaining  = lk_rem[19:7];
    assign lk_next_la    = lk_rem[6:0];
    assign lk_tc         = lk_meta[4:2];
    assign lk_attr       = lk_meta[1:0];

    // ---- timebase ---------------------------------------------------------------------------
    reg [W-1:0] now;
    reg [15:0]  presc;
    always @(posedge clk)
        if (rst) begin
            now <= '0; presc <= 16'd0;
        end else if (presc == 16'(TICK_CYCLES - 1)) begin
            now <= now + 1'b1; presc <= 16'd0;
        end else
            presc <= presc + 16'd1;

    // ---- sweep --------------------------------------------------------------------------------
    reg  [7:0]   sw_idx;
    wire [W+5:0] sw_iss = issr[sw_idx];
    wire [W-1:0] sw_t, sw_q;
    wire [W-1:0] sw_age_iss = now - sw_iss[W+4:5];
    reg  [W-1:0] t_flr;
    // An entry quarantined at issue was RESERVED at an FLR, so its fl is set too: the
    // issue-time arm must come first.
    wire [W-1:0] sw_tq = sw_iss[W+5] ? sw_iss[W+4:5] : fl[sw_idx] ? t_flr : tqr[sw_idx];
    wire [W-1:0] sw_age_q   = now - sw_tq;
    pcileech_req_cto_limits #(.CLK_PCIE_HZ(CLK_PCIE_HZ), .TICK_CYCLES(TICK_CYCLES), .W(W)) i_limits (
        .code(sw_iss[4:1]), .disable_lat(sw_iss[0]), .t_ticks(sw_t), .q_ticks(sw_q));

    wire sw_retired = up_valid && up_retire && (up_tag == sw_idx);
    wire sw_expire  = (st[sw_idx] == `REQ_ST_ISSUED) && !sw_iss[0] && !ctl_disable &&
                      (sw_age_iss >= sw_t) && !sw_retired && !flr;   // FLR quarantines silently
    wire sw_drain   = (st[sw_idx] == `REQ_ST_QUARANTINED) && (sw_age_q >= sw_q) && !sw_retired;

    // ---- supersede: only the newest holder of a host tag can be unsuperseded ----------------
    // Every older live entry with the same host tag was marked when its successor was
    // admitted, so checking the newest recorded holder is enough. The host-tag check
    // rejects a holder that has since been retired and reused under another host tag.
    wire [7:0] sup_old = rev[adm_host_tag];
    // (Marking a FREE holder is harmless: admission clears the flag.)
    wire       sup_hit = adm_valid && (sup_old != adm_tag) && (hostc[sup_old] == adm_host_tag);
    // Same-edge admission makes the old completion ineligible for host delivery.
    assign lk_superseded = sup[lk_tag] || (sup_hit && sup_old == lk_tag);

    wire iss_q = flr || fl[iss_tag];   // issue of an entry RESERVED at an FLR quarantines

    // ---- single-writer RAMs ---------------------------------------------------------------
    always @(posedge clk) if (adm_valid) begin
        meta[adm_tag]     <= {adm_host_tag, adm_tc, adm_attr};
        hostc[adm_tag]    <= adm_host_tag;
        rem_a[adm_tag]    <= {adm_bc, adm_la};
        rev[adm_host_tag] <= adm_tag;
    end
    always @(posedge clk) if (up_valid && !up_retire)
        rem_u[up_tag] <= {up_remaining, up_next_la};
    always @(posedge clk) if (iss_valid && st[iss_tag] == `REQ_ST_RESERVED)
        issr[iss_tag] <= {iss_q, now, ctl_code, ctl_disable};
    always @(posedge clk) if (!rst && sw_expire)
        tqr[sw_idx] <= now;

    // ---- control state ------------------------------------------------------------------------
    always @(posedge clk) begin
        to_valid <= 1'b0;
        if (rst) begin
            for (i = 0; i < 256; i = i + 1) begin
                st[i] <= `REQ_ST_FREE; sup[i] <= 1'b0; lvt[i] <= 1'b0;
                // fl needs no reset: every admission writes it.
            end
            sw_idx      <= 8'd0;
            err_bypass  <= 1'b0;
            err_release <= 1'b0;
            to_tag      <= 8'd0;
            t_flr       <= '0;
        end else begin
            sw_idx <= sw_idx + 8'd1;

            // FLR first: the per-port updates below act on other entries, except a
            // same-cycle retire, which must win (its completion beat the FLR).
            if (flr) begin
                t_flr <= now;
                for (i = 0; i < 256; i = i + 1) begin
                    if (st[i] == `REQ_ST_ISSUED)   st[i] <= `REQ_ST_QUARANTINED;
                    if (st[i] == `REQ_ST_RESERVED || st[i] == `REQ_ST_ISSUED) fl[i] <= 1'b1;
                end
            end

            if (adm_valid) begin
                if (sup_hit) sup[sup_old] <= 1'b1;
                st[adm_tag]   <= `REQ_ST_RESERVED;
                sup[adm_tag]  <= 1'b0;
                lvt[adm_tag]  <= 1'b0;
                fl[adm_tag]   <= flr;
            end

            if (iss_valid) begin
                if (st[iss_tag] == `REQ_ST_RESERVED) begin
                    st[iss_tag] <= iss_q ? `REQ_ST_QUARANTINED : `REQ_ST_ISSUED;
                end else
                    err_bypass <= 1'b1;
            end

            if (rel_valid) begin
                if (st[rel_tag] == `REQ_ST_RESERVED) st[rel_tag]  <= `REQ_ST_FREE;
                else                                 err_release <= 1'b1;
            end

            if (up_valid) begin
                if (up_retire) st[up_tag]  <= `REQ_ST_FREE;
                else           lvt[up_tag] <= 1'b1;
            end

            if (sw_expire) begin
                st[sw_idx] <= `REQ_ST_QUARANTINED;
                to_valid   <= 1'b1;
                to_tag     <= sw_idx;
            end else if (sw_drain)
                st[sw_idx] <= `REQ_ST_FREE;
        end
    end

    // ---- counts: incremental, exact for the current state ---------------------------------
    // Each transition adjusts the count of the state it leaves and the state it enters.
    // The ports act on distinct entries (admit: a FREE tag; issue and release: RESERVED,
    // never the same one; retire: ISSUED/QUARANTINED; a same-entry retire suppresses the
    // sweep), so their deltas add. An FLR moves every ISSUED entry that survives the
    // cycle (n_issued + d_iss: expiry is suppressed and a same-cycle issue goes straight
    // to QUARANTINED) into QUARANTINED.
    // Admission takes only the allocator's offer, which is FREE by construction
    // (free[g] above), so it leaves no counted state. Reading st[adm_tag] here put a
    // 256:1 mux behind the allocator and failed routed setup at n_quarantined.
    // n_live counts ISSUED + QUARANTINED with its own delta. An FLR only moves entries
    // between the two, so the quarantined count after an FLR is n_live + d_live. That
    // keeps one adder on the FLR path instead of n_issued + d_iss feeding a second one.
    wire [1:0] old_up  = st[up_tag];
    wire       iss_ok  = iss_valid && (st[iss_tag] == `REQ_ST_RESERVED);
    reg  [9:0] d_res, d_iss, d_q, d_live;       // two's complement deltas
    reg  [8:0] n_live;                          // n_issued + n_quarantined
    task automatic leave(input [1:0] s);
        case (s)
            `REQ_ST_RESERVED:    d_res = d_res - 10'd1;
            `REQ_ST_ISSUED:      begin d_iss = d_iss - 10'd1; d_live = d_live - 10'd1; end
            `REQ_ST_QUARANTINED: begin d_q   = d_q   - 10'd1; d_live = d_live - 10'd1; end
            default: ;
        endcase
    endtask
    always @* begin
        d_res = 10'd0; d_iss = 10'd0; d_q = 10'd0; d_live = 10'd0;
        if (adm_valid) d_res = d_res + 10'd1;
        if (iss_ok) begin
            d_res = d_res - 10'd1;
            d_live = d_live + 10'd1;
            if (iss_q) d_q   = d_q   + 10'd1;
            else       d_iss = d_iss + 10'd1;
        end
        if (rel_valid && st[rel_tag] == `REQ_ST_RESERVED) d_res = d_res - 10'd1;
        if (up_valid && up_retire) leave(old_up);
        if (sw_expire) begin d_iss = d_iss - 10'd1; d_q = d_q + 10'd1; end
        else if (sw_drain) begin d_q = d_q - 10'd1; d_live = d_live - 10'd1; end
    end
    always @(posedge clk)
        if (rst) begin
            n_reserved <= 9'd0; n_issued <= 9'd0; n_quarantined <= 9'd0; n_live <= 9'd0;
        end else begin
            n_reserved    <= n_reserved    + d_res[8:0];
            n_issued      <= flr ? 9'd0 : n_issued + d_iss[8:0];
            n_quarantined <= flr ? n_live + d_live[8:0] : n_quarantined + d_q[8:0];
            n_live        <= n_live        + d_live[8:0];
        end
    assign trn_pending = (n_reserved != 9'd0) || (n_issued != 9'd0);
    // synthesis translate_off
    always @(posedge clk)
        if (!rst && adm_valid && st[adm_tag] !== `REQ_ST_FREE)
            $error("req_table: admission of non-FREE tag %0d (state %0d)", adm_tag, st[adm_tag]);
    always @(posedge clk)
        if (!rst && n_live !== n_issued + n_quarantined)
            $error("req_table: n_live %0d != n_issued %0d + n_quarantined %0d", n_live, n_issued, n_quarantined);
    // synthesis translate_on
endmodule
