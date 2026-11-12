// Review F1 acceptance: subsystem reset on the RX path.
//
// Models the board RX chain with the real modules: core 64-bit RX ->
// pcileech_tlps128_src64 -> pcileech_req_rx_cpl (+ table) -> the host filter
// pcileech_tlps128_filter -> host. src64 and rx_cpl share the link-session
// reset; the filter (like the other host-side consumers) resets on the
// subsystem reset. OLD_WIRING=1 puts src64 on the subsystem reset too, as the
// reviewed commit did, and is expected to fail (control).
//
// A subsystem-reset pulse of 1 and 4 cycles is swept across every word of a
// stream of five TLPs: CplD 1 DW, CplD 2 DW, MWr32 2 DW, CplD 4 DW with ECRC
// digest, CplD 1 DW. For every position:
//   - every completion retires its table entry (n_issued == 0 at the end);
//   - the host never sees an orphan beat or a nested first beat;
//   - every packet the host sees is identical to the no-reset reference
//     packet in the same position, in order;
//   - packets clear of the reset window are all delivered.
// The host capture discards a packet in progress when the subsystem reset
// asserts. That models pcileech_tlps128_dst_fifo, which is reset by
// rst_subsys_sys (asserted in clk_sys no later than rst_subsys) and blocks
// writes during its reset window, so a head whose tail the filter drops never
// reaches the host. That ordering belongs to pcileech_pcie_a7_rst and is not
// re-verified here.
`timescale 1ns / 1ps
`include "pcileech_header.svh"
module tb_rx_subsys_reset;
    parameter integer OLD_WIRING = 0;
    parameter integer DEBUG_AT = -1, DEBUG_LEN = 1;  // trace one sweep position
    integer cur_at = -2, cur_len = 0;
    localparam integer NPKT = 5, MARGIN = 8;

    reg clk = 1'b0;
    always #8 clk = ~clk;
    reg rst = 1'b1, subsys = 1'b0;

    IfPCIeTlpRxTx core();
    IfAXIS128     conv();
    IfAXIS128     rxo();
    IfAXIS128     host();
    reg [63:0] data = 0;
    reg [7:0]  keep = 0;
    reg        valid = 0, last = 0;
    assign core.data = data; assign core.keep = keep;
    assign core.valid = valid; assign core.last = last; assign core.user = 22'd0;

    pcileech_tlps128_src64 converter(.clk_pcie(clk), .rst(OLD_WIRING != 0 ? (rst || subsys) : rst),
                                     .tlp_rx(core), .tlps_out(conv));

    reg adm = 0, iss = 0;
    reg [7:0] tag = 0, host_tag = 0;
    reg [12:0] bc = 0;
    reg [6:0] la = 0;
    wire [7:0] lk_tag, lk_host, up_tag;
    wire [1:0] lk_state, lk_attr;
    wire lk_sup, up_valid, up_retire;
    wire [12:0] lk_rem, up_rem;
    wire [6:0] lk_la, up_la;
    wire [2:0] lk_tc;
    wire [8:0] n_issued;
    pcileech_req_table entries(.clk(clk), .rst(rst), .flr(1'b0), .ctl_code(4'd1), .ctl_disable(1'b0),
        .adm_valid(adm), .adm_tag(tag), .adm_host_tag(host_tag), .adm_bc(bc), .adm_la(la),
        .adm_tc(3'd0), .adm_attr(2'd0), .iss_valid(iss), .iss_tag(tag),
        .rel_valid(1'b0), .rel_tag(8'd0),
        .lk_tag(lk_tag), .lk_state(lk_state), .lk_host_tag(lk_host), .lk_superseded(lk_sup),
        .lk_remaining(lk_rem), .lk_next_la(lk_la), .lk_tc(lk_tc), .lk_attr(lk_attr),
        .up_valid(up_valid), .up_tag(up_tag), .up_retire(up_retire), .up_remaining(up_rem),
        .up_next_la(up_la), .free(), .to_valid(), .to_tag(), .n_reserved(), .n_issued(n_issued),
        .n_quarantined(), .trn_pending(), .err_bypass(), .err_release());
    pcileech_req_rx_cpl rx(.clk(clk), .rst(rst), .flr(1'b0),
        .in_data(conv.tdata), .in_keep(conv.tkeepdw), .in_user(conv.tuser), .in_last(conv.tlast),
        .in_valid(conv.tvalid),
        .out_data(rxo.tdata), .out_keep(rxo.tkeepdw), .out_user(rxo.tuser), .out_last(rxo.tlast),
        .out_valid(rxo.tvalid),
        .lk_tag(lk_tag), .lk_state(lk_state), .lk_host_tag(lk_host), .lk_superseded(lk_sup),
        .lk_remaining(lk_rem), .lk_next_la(lk_la), .lk_tc(lk_tc), .lk_attr(lk_attr),
        .up_valid(up_valid), .up_tag(up_tag), .up_retire(up_retire), .up_remaining(up_rem),
        .up_next_la(up_la), .unexpected_valid(), .unexpected_header(), .malformed_valid(),
        .malformed_header(), .completed_count(), .unexpected_count(), .mismatch_count(),
        .bcm_count(), .crs_count(), .superseded_count(), .malformed_count());
    pcileech_tlps128_filter filter(.rst(rst || subsys), .clk_pcie(clk), .alltlp_filter(1'b0),
                                   .cfgtlp_filter(1'b0), .tlps_in(rxo), .tlps_out(host));

    // ---- stimulus: five TLPs as 64-bit core words (low DW first) ----
    localparam integer NWORDS = 2 + 3 + 3 + 4 + 2;
    reg [63:0] w_data[0:NWORDS-1];
    reg [7:0]  w_keep[0:NWORDS-1];
    reg        w_last[0:NWORDS-1];
    integer    w_pkt[0:NWORDS-1];
    integer    n = 0;
    task automatic put(input [63:0] d, input [7:0] k, input l, input integer p);
        begin w_data[n] = d; w_keep[n] = k; w_last[n] = l; w_pkt[n] = p; n = n + 1; end
    endtask
    initial begin
        // P0 CplD tag0 1 DW, BC 4
        put(64'h00200004_4a000001, 8'hff, 0, 0);  put(64'haaaa0000_02180000, 8'hff, 1, 0);
        // P1 CplD tag1 2 DW, BC 8
        put(64'h00200008_4a000002, 8'hff, 0, 1);  put(64'h11111111_02180100, 8'hff, 0, 1);
        put(64'h00000000_22222222, 8'h0f, 1, 1);
        // P2 MWr32 2 DW (not a completion; passes unchanged)
        put(64'h021800ff_40000002, 8'hff, 0, 2);  put(64'h33333333_10000000, 8'hff, 0, 2);
        put(64'h00000000_44444444, 8'h0f, 1, 2);
        // P3 CplD tag2 4 DW with ECRC digest (TD), BC 16
        put(64'h00200010_4a008004, 8'hff, 0, 3);  put(64'h55555555_02180200, 8'hff, 0, 3);
        put(64'h77777777_66666666, 8'hff, 0, 3);  put(64'hd16e57d1_88888888, 8'hff, 1, 3);
        // P4 CplD tag3 1 DW, BC 4
        put(64'h00200004_4a000001, 8'hff, 0, 4);  put(64'h99999999_02180300, 8'hff, 1, 4);
    end

    // ---- host capture: per-packet signatures and framing checks ----
    integer errors = 0, checks = 0;
    reg [63:0] sig, got_sig[0:15];
    integer    got_n = 0, beats = 0;
    reg        in_pkt = 0;
    reg [127:0] masked;
    integer    cyc = 0;
    integer    first_cyc[0:NPKT-1], last_cyc[0:NPKT-1];
    task automatic fail(input [8*64-1:0] what);
        begin
            errors = errors + 1;
            if (errors < 20) $display("R1_TB_FAIL tb_rx_subsys_reset %0s @%0t", what, $time);
        end
    endtask
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (cur_at == DEBUG_AT && cur_len == DEBUG_LEN && (rxo.tvalid || host.tvalid || subsys))
            $display("DBG cyc=%0d subsys=%b filt=%b | rxo v=%b f=%b l=%b k=%h d=%h | host v=%b f=%b l=%b k=%h", cyc, subsys, filter.filter,
                     rxo.tvalid, rxo.tuser[0], rxo.tlast, rxo.tkeepdw, rxo.tdata[31:0], host.tvalid, host.tuser[0], host.tlast, host.tkeepdw);
        if (subsys) in_pkt = 0;     // dst_fifo flush (see header)
        if (host.tvalid && !subsys) begin
            masked = {host.tkeepdw[3] ? host.tdata[127:96] : 32'd0, host.tkeepdw[2] ? host.tdata[95:64] : 32'd0,
                      host.tkeepdw[1] ? host.tdata[63:32] : 32'd0, host.tkeepdw[0] ? host.tdata[31:0] : 32'd0};
            if (host.tuser[0]) begin
                if (in_pkt) fail("nested first beat at host");
                in_pkt = 1; sig = 64'h0; beats = 0;
            end else if (!in_pkt) fail("orphan beat at host");
            sig = {sig[62:0], sig[63]} ^ masked[63:0] ^ {masked[127:64]} ^ {55'd0, host.tkeepdw, host.tlast, host.tuser[3:0]};
            beats = beats + 1;
            if (host.tlast) begin
                if (got_n < 16) got_sig[got_n] = sig ^ 64'(beats);
                got_n = got_n + 1;
                in_pkt = 0;
            end
        end
    end

    task automatic tick; @(negedge clk); endtask
    task automatic allocate(input [7:0] t, h, input [12:0] b);
        begin tag = t; host_tag = h; bc = b; la = 0; adm = 1; tick(); adm = 0; iss = 1; tick(); iss = 0; end
    endtask

    // One run: reset, allocate, stream with an optional subsystem pulse.
    integer start_cyc, pulse_at, pulse_len;
    task automatic run_once(input integer at, input integer len);
        integer i, k;
        begin
            rst = 1; subsys = 0; valid = 0; cur_at = at; cur_len = len;
            repeat (3) tick();
            rst = 0; in_pkt = 0; got_n = 0;
            allocate(8'd0, 8'ha0, 13'd4); allocate(8'd1, 8'ha1, 13'd8);
            allocate(8'd2, 8'ha2, 13'd16); allocate(8'd3, 8'ha3, 13'd4);
            repeat (2) tick();
            start_cyc = cyc;
            for (i = 0; i < NWORDS + len + 2; i = i + 1) begin
                if (at >= 0 && i == at) subsys = 1;
                if (at >= 0 && i == at + len) subsys = 0;
                if (i < NWORDS) begin
                    if (i == 0 || w_pkt[i] != w_pkt[i-1]) first_cyc[w_pkt[i]] = cyc;
                    if (w_last[i]) last_cyc[w_pkt[i]] = cyc;
                    data = w_data[i]; keep = w_keep[i]; last = w_last[i]; valid = 1;
                end else valid = 0;
                tick();
            end
            valid = 0; subsys = 0;
            repeat (12) tick();
            k = 0;
        end
    endtask

    reg [63:0] ref_sig[0:NPKT-1];
    integer ref_n;
    integer at, len, i, j, k, matched, pulse_lo, pulse_hi;
    reg clear;
    initial begin
        repeat (2) tick();
        run_once(-1, 0);
        ref_n = got_n;
        for (i = 0; i < NPKT; i = i + 1) ref_sig[i] = got_sig[i];
        checks = checks + 1;
        if (ref_n != NPKT || n_issued != 0 || errors != 0) fail("reference run");
        for (len = 1; len <= 4; len = len + 3) begin
            for (at = 0; at < NWORDS + 2; at = at + 1) begin
                run_once(at, len);
                pulse_lo = start_cyc + at; pulse_hi = start_cyc + at + len;
                checks = checks + 1;
                if (n_issued != 0) begin
                    fail("completion not retired across subsystem reset");
                    if (errors < 20) $display("  at=%0d len=%0d n_issued=%0d", at, len, n_issued);
                end
                // in-order subsequence of the reference, all clear packets present
                j = 0; matched = 1;
                for (i = 0; i < NPKT; i = i + 1) begin
                    clear = last_cyc[i] + MARGIN < pulse_lo || first_cyc[i] > pulse_hi + MARGIN;
                    if (j < got_n && got_sig[j] == ref_sig[i]) j = j + 1;
                    else if (clear) matched = 0;
                end
                checks = checks + 1;
                if (!matched || j != got_n) begin
                    fail("host packets differ from reference");
                    if (errors < 20) $display("  at=%0d len=%0d got=%0d matched_prefix=%0d", at, len, got_n, j);
                end
            end
        end
        if (errors == 0)
            $display("R1_TB_PASS tb_rx_subsys_reset checks=%0d old_wiring=%0d", checks, OLD_WIRING);
        else
            $display("R1_TB_FAILED tb_rx_subsys_reset errors=%0d old_wiring=%0d", errors, OLD_WIRING);
        $finish;
    end
    initial begin
        #5_000_000;
        $display("R1_TB_FAIL tb_rx_subsys_reset watchdog");
        $finish;
    end
endmodule
