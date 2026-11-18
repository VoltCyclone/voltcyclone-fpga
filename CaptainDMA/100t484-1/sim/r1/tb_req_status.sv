// R1 requester status snapshot: coherence, layout, counters and stopped clock.
// Every clk_pcie input is derived from one per-edge counter k, so a snapshot
// is coherent exactly when all fields decode to the same k. Signals the module
// counts itself (timeouts, session aborts) and the flags are checked against a
// per-k history of the expected value at that edge.
`timescale 1ns / 1ps
module tb_req_status;
    parameter integer PCIE_PS = 16000;
    parameter integer SYS_PS  = 10000;

    reg clk_pcie = 1'b0, clk_sys = 1'b0;
    reg pcie_run = 1'b1;
    always #(PCIE_PS / 2000.0) if (pcie_run) clk_pcie = ~clk_pcie;
    always #(SYS_PS / 2000.0) clk_sys = ~clk_sys;

    reg [15:0] k = 16'd0;
    reg rst_pcie = 1'b0, timeout_valid = 1'b0;
    wire [511:0] ro;

    wire [111:0] refuse;
    genvar g;
    generate for (g = 0; g < 7; g = g + 1) begin : g_ref
        assign refuse[g*16 +: 16] = k + 16'(20 + g);
    end endgenerate

    pcileech_req_status dut (
        .clk_pcie(clk_pcie), .rst_pcie(rst_pcie),
        .admitted_count((k + 16'd1)), .refuse_counts(refuse),
        .n_reserved(9'((k + 16'd30))), .n_issued(9'((k + 16'd31))), .n_quarantined(9'((k + 16'd32))),
        .timeout_valid(timeout_valid),
        .err_bypass(k[3]), .err_release(k[4]),
        .completed_count((k + 16'd2)), .unexpected_count((k + 16'd3)), .malformed_count((k + 16'd4)),
        .superseded_count((k + 16'd5)), .mismatch_count((k + 16'd6)), .bcm_count((k + 16'd7)),
        .crs_count((k + 16'd8)), .tx_drop_count((k + 16'd9)),
        .err_reported_count((k + 16'd10)), .err_suppressed_count((k + 16'd11)),
        .err_overflow_count((k + 16'd12)),
        .err_level(10'((k + 16'd33))), .err_high_water(10'((k + 16'd34))),
        .err_overflow(k[5]),
        .clk_sys(clk_sys), .ro_status(ro));

    // ---- reference model of the module-owned clk_pcie state, per edge ----
    reg [15:0] m_to = 16'd0, m_ab = 16'd0;
    reg m_rst_d = 1'b0;
    reg [15:0] h_to[0:65535], h_ab[0:65535];
    reg h_rst[0:65535];
    always @(posedge clk_pcie) begin
        h_to[k] = m_to; h_ab[k] = m_ab; h_rst[k] = rst_pcie;
        if (rst_pcie) m_to <= 16'd0;
        else if (timeout_valid && m_to != 16'hffff) m_to <= m_to + 16'd1;
        if (rst_pcie && !m_rst_d && m_ab != 16'hffff) m_ab <= m_ab + 16'd1;
        m_rst_d <= rst_pcie;
        k <= k + 16'd1;
    end

    integer errors = 0, checks = 0, snaps = 0;
    task automatic fail(input [8*64-1:0] what);
        begin
            errors = errors + 1;
            if (errors < 20) $display("R1_TB_FAIL tb_req_status %0s @%0t", what, $time);
        end
    endtask
    task automatic expect16(input [15:0] got, input [15:0] want, input [8*64-1:0] what);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fail(what);
                if (errors < 20) $display("  got %h want %h", got, want);
            end
        end
    endtask
    function automatic [15:0] w(input integer byte_offset);
        w = ro[byte_offset*8 +: 16];
    endfunction

    // ---- check every published snapshot ----
    reg [511:0] prev_ro;
    reg have_prev = 1'b0;
    reg [15:0] kk;
    integer i;
    always @(posedge clk_sys) begin
        #1;
        if (have_prev && ro !== prev_ro) begin
            snaps = snaps + 1;
            kk = w('h0E) - 16'd1;
            expect16(w('h00), 16'h5201, "magic");
            expect16(w('h02), {11'd0, kk[5], kk[4], kk[3], h_rst[kk], 1'b1}, "flags");
            // Every capture is delivered, so the sequence advances by exactly one.
            expect16(w('h04), prev_ro[16] ? prev_ro[4*8 +: 16] + 16'd1 : 16'd0, "sequence step");
            expect16(w('h06), h_ab[kk], "session aborts");
            expect16(w('h08), {7'd0, 9'(kk + 16'd30)}, "RESERVED count");
            expect16(w('h0A), {7'd0, 9'(kk + 16'd31)}, "ISSUED count");
            expect16(w('h0C), {7'd0, 9'(kk + 16'd32)}, "QUARANTINED count");
            expect16(w('h10), kk + 16'd2, "completed");
            expect16(w('h12), h_to[kk], "timed_out");
            expect16(w('h14), kk + 16'd3, "unexpected");
            expect16(w('h16), kk + 16'd4, "malformed");
            expect16(w('h18), kk + 16'd5, "superseded");
            expect16(w('h1A), kk + 16'd6, "mismatch");
            expect16(w('h1C), kk + 16'd7, "bcm");
            expect16(w('h1E), kk + 16'd8, "crs");
            for (i = 0; i < 7; i = i + 1)
                expect16(w('h20 + 2*i), kk + 16'(20 + i), "refuse reason");
            expect16(w('h2E), kk + 16'd9, "tx_err_drop");
            expect16(w('h30), kk + 16'd10, "err reported");
            expect16(w('h32), kk + 16'd11, "err suppressed");
            expect16(w('h34), kk + 16'd12, "err overflow count");
            expect16(w('h36), {6'd0, 10'(kk + 16'd33)}, "err level");
            expect16(w('h38), {6'd0, 10'(kk + 16'd34)}, "err high water");
            for (i = 'h3A; i < 'h40; i = i + 2) expect16(w(i), 16'd0, "reserved");
            // Liveness: the published value lags the live counter by a bounded
            // amount. The model's synchronizer jitter can repeat, so the bound
            // allows ~30 sys periods rather than the nominal ~8.
            checks = checks + 1;
            if (16'(k - kk) > 16'(40 + 30 * (SYS_PS + PCIE_PS - 1) / PCIE_PS))
                begin fail("stale snapshot"); $display("  lag=%0d", 16'(k - kk)); end
        end
        prev_ro = ro;
        have_prev = 1'b1;
    end

    task automatic pcie_cycles(input integer n);
        repeat (n) @(posedge clk_pcie);
    endtask
    integer last_snaps;
    reg [511:0] frozen;
    initial begin
        // Before the first delivery: magic, flags/data all zero, valid low.
        #1;
        expect16(w('h00), 16'h5201, "initial magic");
        expect16(w('h02), 16'd0, "initial invalid");
        expect16(w('h04), 16'd0, "initial data");

        pcie_cycles(400);
        // Timeouts count, saturate and reset on link session abort only.
        @(negedge clk_pcie) timeout_valid = 1'b1;
        pcie_cycles(70000);
        @(negedge clk_pcie) timeout_valid = 1'b0;
        pcie_cycles(200);
        expect16(dut.timed_out_count, 16'hffff, "timed_out saturates");
        // Session aborts: count rising edges, survive the abort, saturate.
        repeat (5) begin
            @(negedge clk_pcie) rst_pcie = 1'b1;
            pcie_cycles(3);
            @(negedge clk_pcie) rst_pcie = 1'b0;
            pcie_cycles(60);
        end
        expect16(dut.session_aborts, 16'd5, "session aborts counted");
        expect16(dut.timed_out_count, 16'd0, "timed_out reset by abort");
        // Long abort: flag visible in snapshots while held.
        @(negedge clk_pcie) rst_pcie = 1'b1;
        @(negedge clk_pcie) timeout_valid = 1'b1;
        pcie_cycles(300);
        @(negedge clk_pcie) rst_pcie = 1'b0;
        pcie_cycles(20);
        @(negedge clk_pcie) timeout_valid = 1'b0;
        pcie_cycles(200);
        repeat (65540) begin
            @(negedge clk_pcie) rst_pcie = 1'b1;
            @(negedge clk_pcie) rst_pcie = 1'b0;
        end
        pcie_cycles(5);
        expect16(dut.session_aborts, 16'hffff, "session aborts saturate");
        pcie_cycles(300);

        // Stopped clk_pcie: last snapshot stays readable and valid.
        pcie_run = 1'b0;
        repeat (50) @(posedge clk_sys);
        frozen = ro;
        last_snaps = snaps;
        repeat (500) @(posedge clk_sys);
        checks = checks + 1;
        if (ro !== frozen || snaps != last_snaps || !ro[16]) fail("stopped clock changed snapshot");
        pcie_run = 1'b1;
        pcie_cycles(400);
        checks = checks + 1;
        if (snaps == last_snaps) fail("no snapshot after clock restart");

        checks = checks + 1;
        if (snaps < 100) fail("too few snapshots");
        if (errors == 0)
            $display("R1_TB_PASS tb_req_status checks=%0d snapshots=%0d pcie_ps=%0d sys_ps=%0d",
                     checks, snaps, PCIE_PS, SYS_PS);
        else
            $display("R1_TB_FAILED tb_req_status errors=%0d", errors);
        $finish;
    end
endmodule
