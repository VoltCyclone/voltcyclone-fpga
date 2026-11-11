// Self-checking bench for pcileech_req_table (MSIX_REQUESTER_CONTRACT.md sections 4, 6,
// 8, 9). One tick per clock (TICK_CYCLES = 1 at 62.5 MHz: 16 ns ticks), so code 0001
// gives T = ceil(90 us / 16 ns) = 5625 ticks and Q = ceil(100 us / 16 ns) = 6250 ticks.
// The sweep visits one entry per cycle, so an entry is seen at least every 256 cycles.
// Prints R1_TB_PASS on success.
`timescale 1ns / 1ps
`include "pcileech_req_defs.svh"

module tb_req_table;
    localparam int T0001 = 5625, Q0001 = 6250, SWEEP = 256, SLACK = 4;

    reg         clk = 0, rst = 1;
    reg  [3:0]  ctl_code = 4'b0001;
    reg         ctl_disable = 0;
    reg         adm_valid = 0, iss_valid = 0, up_valid = 0, up_retire = 0, flr = 0, rel_valid = 0;
    reg  [7:0]  adm_tag = 0, adm_host_tag = 0, iss_tag = 0, lk_tag = 0, up_tag = 0, rel_tag = 0;
    reg  [12:0] adm_bc = 0, up_remaining = 0;
    reg  [6:0]  adm_la = 0, up_next_la = 0;
    reg  [2:0]  adm_tc = 0;
    reg  [1:0]  adm_attr = 0;
    wire [1:0]  lk_state;
    wire [7:0]  lk_host_tag, to_tag;
    wire        lk_superseded, to_valid, trn_pending, err_bypass, err_release;
    wire [12:0] lk_remaining;
    wire [6:0]  lk_next_la;
    wire [2:0]  lk_tc;
    wire [1:0]  lk_attr;
    wire [255:0] free;
    wire [8:0]  n_reserved, n_issued, n_quarantined;

    pcileech_req_table #(.CLK_PCIE_HZ(62_500_000), .TICK_CYCLES(1), .W(34)) dut (
        .clk(clk), .rst(rst), .flr(flr), .ctl_code(ctl_code), .ctl_disable(ctl_disable),
        .adm_valid(adm_valid), .adm_tag(adm_tag), .adm_host_tag(adm_host_tag), .adm_bc(adm_bc),
        .adm_la(adm_la), .adm_tc(adm_tc), .adm_attr(adm_attr),
        .iss_valid(iss_valid), .iss_tag(iss_tag), .rel_valid(rel_valid), .rel_tag(rel_tag),
        .lk_tag(lk_tag), .lk_state(lk_state), .lk_host_tag(lk_host_tag), .lk_superseded(lk_superseded),
        .lk_remaining(lk_remaining), .lk_next_la(lk_next_la), .lk_tc(lk_tc), .lk_attr(lk_attr),
        .up_valid(up_valid), .up_tag(up_tag), .up_retire(up_retire), .up_remaining(up_remaining),
        .up_next_la(up_next_la),
        .free(free), .to_valid(to_valid), .to_tag(to_tag), .n_reserved(n_reserved), .n_issued(n_issued),
        .n_quarantined(n_quarantined), .trn_pending(trn_pending), .err_bypass(err_bypass),
        .err_release(err_release));

    always #8 clk = ~clk;

    integer errors = 0, checks = 0;
    longint cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;

    // timeout event log
    integer to_count = 0;
    longint to_cycle = 0;
    reg [7:0] to_last = 0;
    always @(posedge clk) if (!rst && to_valid) begin
        to_count <= to_count + 1; to_cycle <= cycle; to_last <= to_tag;
    end

    // Invariant, every cycle: the counts equal the current table state (no lag).
    integer inv_errors = 0;
    reg [8:0] pc_res, pc_iss, pc_q;
    always @(negedge clk) begin
        pc_res = 0; pc_iss = 0; pc_q = 0;
        for (int k = 0; k < 256; k++) begin
            pc_res += (dut.st[k] == `REQ_ST_RESERVED);
            pc_iss += (dut.st[k] == `REQ_ST_ISSUED);
            pc_q   += (dut.st[k] == `REQ_ST_QUARANTINED);
        end
        if (!rst && (n_reserved !== pc_res || n_issued !== pc_iss || n_quarantined !== pc_q)) begin
            if (inv_errors < 5)
                $display("R1_TB_FAIL count invariant (cycle %0d): res %0d/%0d iss %0d/%0d q %0d/%0d", cycle,
                         n_reserved, pc_res, n_issued, pc_iss, n_quarantined, pc_q);
            inv_errors = inv_errors + 1;
        end
    end

    task check;
        input [8*64-1:0] name; input ok;
        begin
            checks = checks + 1;
            if (!ok) begin errors = errors + 1; $display("R1_TB_FAIL %0s (cycle %0d)", name, cycle); end
        end
    endtask

    task expect_state;
        input [8*64-1:0] name; input [7:0] tag; input [1:0] st;
        begin
            lk_tag = tag; #1;
            checks = checks + 1;
            if (lk_state !== st || free[tag] !== (st == `REQ_ST_FREE)) begin
                errors = errors + 1;
                $display("R1_TB_FAIL %0s: tag %0d state=%0d free=%b want %0d", name, tag, lk_state, free[tag], st);
            end
        end
    endtask

    task admit;
        input [7:0] tag; input [7:0] host; input [12:0] bc; input [6:0] la; input [2:0] t_c; input [1:0] at;
        begin
            @(negedge clk);
            adm_valid = 1; adm_tag = tag; adm_host_tag = host; adm_bc = bc; adm_la = la; adm_tc = t_c; adm_attr = at;
            @(negedge clk); adm_valid = 0;
        end
    endtask

    longint iss_cycle;
    task issue;
        input [7:0] tag;
        begin
            @(negedge clk); iss_valid = 1; iss_tag = tag;
            @(posedge clk); iss_cycle = cycle;
            @(negedge clk); iss_valid = 0;
        end
    endtask

    task update;
        input [7:0] tag; input retire; input [12:0] rem; input [6:0] la;
        begin
            @(negedge clk); up_valid = 1; up_tag = tag; up_retire = retire; up_remaining = rem; up_next_la = la;
            @(negedge clk); up_valid = 0; up_retire = 0;
        end
    endtask

    longint flr_cycle;
    task flr_pulse;
        begin
            @(negedge clk); flr = 1;
            @(posedge clk); flr_cycle = cycle;
            @(negedge clk); flr = 0;
        end
    endtask

    task release_tag;
        input [7:0] tag;
        begin
            @(negedge clk); rel_valid = 1; rel_tag = tag;
            @(negedge clk); rel_valid = 0;
        end
    endtask

    // wait for an entry to return to FREE and check it did so inside [start + Q, start + Q + sweep]
    task expect_drain;
        input [8*64-1:0] name; input [7:0] tag; input longint start;
        begin
            wait (free[tag] === 1'b1 || cycle > start + Q0001 + SWEEP + SLACK);
            checks = checks + 1;
            if (!(free[tag] === 1'b1 && cycle - start >= Q0001 && cycle - start <= Q0001 + SWEEP + SLACK)) begin
                errors = errors + 1;
                $display("R1_TB_FAIL %0s: tag %0d free=%b after %0d cycles, want [%0d, %0d]", name, tag,
                         free[tag], cycle - start, Q0001, Q0001 + SWEEP + SLACK);
            end
        end
    endtask

    task wait_cycles;
        input longint n;
        repeat (n) @(posedge clk);
    endtask

    task session_reset;
        begin
            @(negedge clk); rst = 1; ctl_code = 4'b0001; ctl_disable = 0;
            @(negedge clk); @(negedge clk); rst = 0;
            @(negedge clk);
        end
    endtask

    integer base;
    initial begin
        session_reset;

        // ---- reset -----------------------------------------------------------------------
        check("reset: all entries FREE", free === {256{1'b1}});
        check("reset: counts zero", n_reserved === 0 && n_issued === 0 && n_quarantined === 0);
        check("reset: no transactions pending", trn_pending === 1'b0);
        check("reset: no bypass error", err_bypass === 1'b0);

        // ---- admit, issue, progress, retire ---------------------------------------------
        admit(8'd3, 8'h41, 13'd200, 7'h24, 3'd5, 2'b10);
        expect_state("admit -> RESERVED", 8'd3, `REQ_ST_RESERVED);
        lk_tag = 8'd3; #1;
        check("admit stores fields", lk_host_tag === 8'h41 && lk_remaining === 13'd200 &&
              lk_next_la === 7'h24 && lk_tc === 3'd5 && lk_attr === 2'b10 && lk_superseded === 1'b0);
        @(negedge clk);
        check("RESERVED counts as pending", n_reserved === 1 && trn_pending === 1'b1);

        issue(8'd3);
        expect_state("issue -> ISSUED", 8'd3, `REQ_ST_ISSUED);
        @(negedge clk);
        check("ISSUED counted", n_reserved === 0 && n_issued === 1 && trn_pending === 1'b1);

        update(8'd3, 1'b0, 13'd136, 7'h68);
        expect_state("progress keeps ISSUED", 8'd3, `REQ_ST_ISSUED);
        lk_tag = 8'd3; #1;
        check("progress writes remaining and next LA", lk_remaining === 13'd136 && lk_next_la === 7'h68);

        update(8'd3, 1'b1, 13'd0, 7'h00);
        expect_state("retire -> FREE", 8'd3, `REQ_ST_FREE);
        admit(8'd3, 8'h42, 13'd64, 7'h10, 3'd0, 2'b00);
        lk_tag = 8'd3; #1;
        check("re-admit after a progress update reads the new fields", lk_remaining === 13'd64 && lk_next_la === 7'h10);
        update(8'd3, 1'b1, 13'd0, 7'h00);
        @(negedge clk);
        check("retire clears pending", n_issued === 0 && trn_pending === 1'b0);

        // ---- bypass: issue for a tag that is not RESERVED ----------------------------------
        issue(8'd4);
        expect_state("issue of a FREE tag changes nothing", 8'd4, `REQ_ST_FREE);
        check("issue of a FREE tag sets sticky err_bypass", err_bypass === 1'b1);
        wait_cycles(3);
        check("err_bypass stays set", err_bypass === 1'b1);
        session_reset;
        check("session abort clears err_bypass", err_bypass === 1'b0);

        // ---- timeout window, code 0001 ----------------------------------------------------
        to_count = 0;
        wait_cycles(3000);                 // issue far from reset: the issue time must matter
        admit(8'd7, 8'h07, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd7);
        wait (to_count != 0 || cycle > iss_cycle + T0001 + SWEEP + SLACK);
        check("timeout event raised", to_count == 1 && to_last == 8'd7);
        check("timeout not before T", to_cycle - iss_cycle >= T0001);
        check("timeout within T + sweep", to_cycle - iss_cycle <= T0001 + SWEEP + SLACK);
        expect_state("timeout -> QUARANTINED", 8'd7, `REQ_ST_QUARANTINED);
        @(negedge clk);
        check("QUARANTINED counted, not pending", n_quarantined === 1 && n_issued === 0 && trn_pending === 1'b0);

        // ---- drain: QUARANTINED -> FREE after Q ------------------------------------------
        begin : drain
            longint q_start;
            q_start = to_cycle;
            wait (free[7] === 1'b1 || cycle > q_start + Q0001 + SWEEP + SLACK);
            check("drain releases the tag", free[7] === 1'b1);
            check("drain not before Q", cycle - q_start >= Q0001);
            check("drain within Q + sweep", cycle - q_start <= Q0001 + SWEEP + SLACK);
            check("one timeout event only", to_count == 1);
        end

        // ---- late completion frees a QUARANTINED entry at once ----------------------------
        to_count = 0;
        admit(8'd8, 8'h08, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd8);
        wait (to_count != 0 || cycle > iss_cycle + T0001 + SWEEP + SLACK);
        expect_state("quarantined before the late completion", 8'd8, `REQ_ST_QUARANTINED);
        update(8'd8, 1'b1, 13'd0, 7'h00);
        expect_state("late final completion -> FREE", 8'd8, `REQ_ST_FREE);

        // ---- Disable latched at issue: never expires, even after the live bit clears ------
        session_reset; to_count = 0;
        ctl_disable = 1;
        admit(8'd9, 8'h09, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd9);
        @(negedge clk); ctl_disable = 0;
        wait_cycles(T0001 + 2 * SWEEP);
        check("latched Disable: no timeout", to_count == 0);
        expect_state("latched Disable: stays ISSUED", 8'd9, `REQ_ST_ISSUED);

        // ---- live Disable suppresses expiry while set -------------------------------------
        session_reset; to_count = 0;
        admit(8'd10, 8'h0A, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd10);
        wait_cycles(100);
        @(negedge clk); ctl_disable = 1;
        wait_cycles(T0001 + 2 * SWEEP);
        check("live Disable: no timeout while set", to_count == 0);
        expect_state("live Disable never frees or quarantines", 8'd10, `REQ_ST_ISSUED);
        @(negedge clk); ctl_disable = 0;
        base = cycle;
        wait (to_count != 0 || cycle > base + SWEEP + SLACK);
        check("live Disable cleared: expires within one sweep", to_count == 1 && to_last == 8'd10);

        // ---- limit code latched at issue ----------------------------------------------------
        session_reset; to_count = 0;
        admit(8'd11, 8'h0B, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd11);
        @(negedge clk); ctl_code = 4'b0010;            // 1-10 ms; must not apply to tag 11
        wait (to_count != 0 || cycle > iss_cycle + T0001 + SWEEP + SLACK);
        check("latched code 0001 still governs", to_count == 1 && to_last == 8'd11);

        // ---- same-cycle final completion and deadline: the completion wins ---------------
        session_reset; to_count = 0;
        admit(8'd12, 8'h0C, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd12);
        // drive the retire in exactly the cycle the sweep would expire tag 12
        @(negedge clk); up_tag = 8'd12; up_retire = 1'b1; up_remaining = 0; up_next_la = 0;
        while (!(dut.sw_idx == 8'd12 && dut.sw_expire) && cycle <= iss_cycle + T0001 + SWEEP + SLACK)
            @(negedge clk);
        check("sweep reached tag 12 at its deadline", dut.sw_idx == 8'd12 && dut.sw_expire);
        up_valid = 1; @(negedge clk); up_valid = 0; up_retire = 0;
        wait_cycles(SWEEP + SLACK);
        check("retire beats same-cycle expiry: no timeout event", to_count == 0);
        expect_state("retire beats same-cycle expiry: FREE", 8'd12, `REQ_ST_FREE);

        // ---- superseded host tags -----------------------------------------------------------
        session_reset;
        admit(8'd20, 8'h55, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd20);
        admit(8'd21, 8'h66, 13'd4, 7'h00, 3'd0, 2'b00);
        admit(8'd22, 8'h55, 13'd4, 7'h00, 3'd0, 2'b00);   // host reuses tag 0x55
        lk_tag = 8'd20; #1; check("older entry with same host tag is superseded", lk_superseded === 1'b1);
        lk_tag = 8'd21; #1; check("other host tag untouched", lk_superseded === 1'b0);
        lk_tag = 8'd22; #1; check("newest entry not superseded", lk_superseded === 1'b0);
        update(8'd20, 1'b1, 13'd0, 7'h00);
        admit(8'd23, 8'h55, 13'd4, 7'h00, 3'd0, 2'b00);
        lk_tag = 8'd22; #1; check("newer admission supersedes 22", lk_superseded === 1'b1);
        admit(8'd20, 8'h77, 13'd4, 7'h00, 3'd0, 2'b00);   // reuse of a FREE entry
        lk_tag = 8'd20; #1; check("re-admitted entry starts not superseded", lk_superseded === 1'b0);
        // newest holder of 0x55 (23) retires and its tag is reused under another host tag;
        // a later 0x55 admission must not supersede the unrelated reuse
        update(8'd23, 1'b1, 13'd0, 7'h00);
        admit(8'd23, 8'h88, 13'd4, 7'h00, 3'd0, 2'b00);
        admit(8'd24, 8'h55, 13'd4, 7'h00, 3'd0, 2'b00);
        lk_tag = 8'd23; #1; check("reused tag under another host tag not superseded", lk_superseded === 1'b0);
        lk_tag = 8'd22; #1; check("older 0x55 entry stays superseded", lk_superseded === 1'b1);
        lk_tag = 8'd24; #1; check("newest 0x55 entry not superseded", lk_superseded === 1'b0);
        update(8'd23, 1'b1, 13'd0, 7'h00);
        update(8'd24, 1'b1, 13'd0, 7'h00);

        // ---- counts and session abort ------------------------------------------------------
        @(negedge clk);
        check("counts track states", n_reserved === 3 && n_issued === 0 && n_quarantined === 0);
        issue(8'd21);
        @(negedge clk);
        check("counts after issue", n_reserved === 2 && n_issued === 1);
        session_reset;
        check("session abort frees every entry", free === {256{1'b1}} && n_reserved === 0 && n_issued === 0);

        to_count = 0;
        admit(8'd30, 8'h30, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd30);
        wait (to_count != 0 || cycle > iss_cycle + T0001 + SWEEP + SLACK);
        session_reset;
        check("session abort frees QUARANTINED entries", free[30] === 1'b1 && n_quarantined === 0);

        // ---- release (discard of a RESERVED packet) ------------------------------------------
        session_reset;
        admit(8'd60, 8'h60, 13'd4, 7'h00, 3'd0, 2'b00);
        release_tag(8'd60);
        expect_state("release of a RESERVED entry -> FREE", 8'd60, `REQ_ST_FREE);
        check("release is not an error", err_release === 1'b0);
        @(negedge clk);
        check("release clears pending", n_reserved === 0 && trn_pending === 1'b0);
        admit(8'd61, 8'h61, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd61);
        release_tag(8'd61);
        expect_state("release of an ISSUED entry changes nothing", 8'd61, `REQ_ST_ISSUED);
        check("release of a non-RESERVED entry sets sticky err_release", err_release === 1'b1);
        session_reset;
        check("session abort clears err_release", err_release === 1'b0);

        // ---- FLR: ISSUED -> QUARANTINED, drain from the FLR; RESERVED resolved by its packet --
        to_count = 0;
        admit(8'd40, 8'h40, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd40);
        wait_cycles(1000);                 // drain must count from the FLR, not the issue
        admit(8'd41, 8'h41, 13'd4, 7'h00, 3'd0, 2'b00);   // accepted after the FLR
        admit(8'd42, 8'h42, 13'd4, 7'h00, 3'd0, 2'b00);   // discarded after the FLR
        admit(8'd44, 8'h44, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd44);                      // late completion after the FLR
        flr_pulse;
        expect_state("FLR: ISSUED -> QUARANTINED", 8'd40, `REQ_ST_QUARANTINED);
        expect_state("FLR: RESERVED waits for its packet", 8'd41, `REQ_ST_RESERVED);
        expect_state("FLR: second RESERVED waits for its packet", 8'd42, `REQ_ST_RESERVED);
        @(negedge clk);
        check("FLR: no ISSUED entries remain", n_issued === 0 && n_quarantined === 2);
        release_tag(8'd42);
        expect_state("FLR: discarded RESERVED -> FREE", 8'd42, `REQ_ST_FREE);
        wait_cycles(500);                  // drain of 41 must count from its issue, not the FLR
        issue(8'd41);
        begin : flr_issue
            longint i41;
            i41 = iss_cycle;
            expect_state("FLR: RESERVED accepted after the FLR -> QUARANTINED", 8'd41, `REQ_ST_QUARANTINED);
            check("FLR: accepted doomed packet is not a bypass", err_bypass === 1'b0);
            @(negedge clk);
            check("FLR: Transactions Pending clears", trn_pending === 1'b0);
            update(8'd44, 1'b1, 13'd0, 7'h00);
            expect_state("FLR: late completion frees a FLR-quarantined entry", 8'd44, `REQ_ST_FREE);
            expect_drain("FLR: ISSUED entry drains Q after the FLR", 8'd40, flr_cycle);
            expect_drain("FLR: post-FLR accepted entry drains Q after its issue", 8'd41, i41);
        end
        check("FLR: no timeout event for FLR entries", to_count == 0);
        admit(8'd42, 8'h42, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd42);
        expect_state("re-admitted entry after an FLR issues normally", 8'd42, `REQ_ST_ISSUED);
        update(8'd42, 1'b1, 13'd0, 7'h00);
        // tag 40 was FLR-quarantined: reused, its timeout drain must start at its own expiry
        to_count = 0;
        wait_cycles(1000);
        admit(8'd40, 8'h40, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd40);
        wait (to_count != 0 || cycle > iss_cycle + T0001 + SWEEP + SLACK);
        check("reused FLR entry times out normally", to_count == 1 && to_last == 8'd40);
        expect_drain("reused FLR entry drains Q after its timeout", 8'd40, to_cycle);

        // FLR leaves timeout-QUARANTINED entries on their own drain
        to_count = 0;
        admit(8'd50, 8'h50, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd50);
        wait (to_count != 0 || cycle > iss_cycle + T0001 + SWEEP + SLACK);
        begin : flr_q
            longint q50;
            q50 = to_cycle;
            wait_cycles(2000);
            flr_pulse;
            expect_drain("FLR does not restart a timeout drain", 8'd50, q50);
        end

        // FLR in the same cycle as admit, issue, retire, and a sweep expiry
        session_reset; to_count = 0;
        admit(8'd70, 8'h70, 13'd4, 7'h00, 3'd0, 2'b00);   // issued in the FLR cycle
        admit(8'd71, 8'h71, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd71);                                       // retired in the FLR cycle
        @(negedge clk);
        flr = 1;
        adm_valid = 1; adm_tag = 8'd72; adm_host_tag = 8'h72; adm_bc = 4; adm_la = 0; adm_tc = 0; adm_attr = 0;
        iss_valid = 1; iss_tag = 8'd70;
        up_valid = 1; up_tag = 8'd71; up_retire = 1; up_remaining = 0; up_next_la = 0;
        @(posedge clk); flr_cycle = cycle;
        @(negedge clk); flr = 0; adm_valid = 0; iss_valid = 0; up_valid = 0; up_retire = 0;
        expect_state("FLR + issue same cycle -> QUARANTINED", 8'd70, `REQ_ST_QUARANTINED);
        expect_state("FLR + retire same cycle: completion wins -> FREE", 8'd71, `REQ_ST_FREE);
        expect_state("FLR + admit same cycle -> RESERVED", 8'd72, `REQ_ST_RESERVED);
        issue(8'd72);
        expect_state("admitted in the FLR cycle is doomed: issue -> QUARANTINED", 8'd72, `REQ_ST_QUARANTINED);
        release_tag(8'd72);                                 // not RESERVED any more
        session_reset;
        admit(8'd72, 8'h72, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd72);
        expect_state("session abort clears the FLR doom", 8'd72, `REQ_ST_ISSUED);

        session_reset; to_count = 0;
        admit(8'd80, 8'h80, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd80);
        while (!(dut.sw_idx == 8'd80 && dut.sw_expire) && cycle <= iss_cycle + T0001 + SWEEP + SLACK)
            @(negedge clk);
        check("sweep reached tag 80 at its deadline", dut.sw_idx == 8'd80 && dut.sw_expire);
        flr = 1; @(posedge clk); flr_cycle = cycle; @(negedge clk); flr = 0;
        wait_cycles(2);
        check("FLR + same-cycle expiry: no timeout event", to_count == 0);
        expect_state("FLR + same-cycle expiry -> QUARANTINED", 8'd80, `REQ_ST_QUARANTINED);
        expect_drain("FLR + same-cycle expiry drains from the FLR", 8'd80, flr_cycle);

        // FLR of an entry latched with Disable: drain interval is 64 s
        session_reset;
        ctl_disable = 1;
        admit(8'd90, 8'h90, 13'd4, 7'h00, 3'd0, 2'b00);
        issue(8'd90);
        @(negedge clk); ctl_disable = 0;
        flr_pulse;
        expect_state("FLR of a Disable-latched entry -> QUARANTINED", 8'd90, `REQ_ST_QUARANTINED);
        wait (dut.sw_idx == 8'd90); #1;
        check("Disable-latched FLR drain is 64 s", 64'(dut.sw_q) == 64'd4_000_000_000);
        wait_cycles(Q0001 + 2 * SWEEP);
        expect_state("Disable-latched FLR entry still QUARANTINED after Q(0001)", 8'd90, `REQ_ST_QUARANTINED);

        check("count invariant held every cycle", inv_errors == 0);
        if (errors == 0) $display("R1_TB_PASS tb_req_table checks=%0d", checks);
        else             $display("R1_TB_FAILED tb_req_table errors=%0d checks=%0d", errors, checks);
        $finish;
    end

    initial begin
        #(64'd400_000_000);
        $display("R1_TB_FAILED tb_req_table watchdog");
        $finish;
    end
endmodule
