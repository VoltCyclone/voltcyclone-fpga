// R4 acceptance: requester history survives a live-link host subsystem reset.
//
// Runs the production pcileech_pcie_a7 (reset generator, TX drain, requester
// tracker, src64/dst64) with the PCIe core, tlp_a7 and cfg_a7 replaced by
// stubs (run_a7_reset_scope.py builds them). The core stub drives the user
// clock, user reset and link-up from this bench; the tlp_a7 stub reports the
// TX mux idle one clock after tx_stop (no packet open).
//
// Contract (MSIX_REQUESTER_CONTRACT.md section 6): the tracker's only reset is
// the link-session abort (global rst, core user reset). A host subsystem reset
// on a live link must not reach it, because completions for outstanding reads
// may still arrive. The bench checks the reset pin of every tracker instance:
//   - phase A: host subsystem resets of several lengths; each one must reach
//     the clk_pcie subsystem reset (rst_subsys) and none may reach a tracker
//     pin (A7_SCOPE_LEAK <pin>);
//   - phase B, positive control: a core user reset must reach every tracker
//     pin (A7_SCOPE_MISSING <pin>).
`timescale 1ns / 1ps
`include "pcileech_header.svh"
module tb_a7_reset_scope;
    reg clk_sys = 1'b0, clk_pcie = 1'b0;
    always #5 clk_sys = ~clk_sys;           // 100 MHz
    always #8 clk_pcie = ~clk_pcie;         // 62.5 MHz core user clock
    reg rst = 1'b1, user_rst = 1'b1, host_soft = 1'b0;

    IfPCIeFifoCfg   dfifo_cfg();
    IfPCIeFifoTlp   dfifo_tlp();
    IfPCIeFifoCore  dfifo_pcie();
    IfShadow2Fifo   dshadow2fifo();
    assign dfifo_pcie.pcie_rst_core   = 1'b0;
    assign dfifo_pcie.pcie_rst_subsys = host_soft;

    wire [0:0] pcie_tx_p, pcie_tx_n;
    wire led_state;
    pcileech_pcie_a7 #(
        .REQ_CLK_PCIE_HZ(64'd62_500_000),
        .DRP_PLAN_BOUND(1), .DRP_PLAN_MASK(16'h00f0), .DRP_PLAN_VALUE(16'h0050),
        .DRP_PLAN_CHECK_MASK(16'h0f00), .DRP_PLAN_BASE_EXPECT(16'h0200),
        .DRP_RDY_TIMEOUT_CYCLES(64)
    ) dut (
        .clk_sys(clk_sys), .rst(rst),
        .pcie_tx_p(pcie_tx_p), .pcie_tx_n(pcie_tx_n),
        .pcie_rx_p(1'b0), .pcie_rx_n(1'b1), .pcie_clk_p(1'b0), .pcie_clk_n(1'b1),
        .pcie_perst_n(1'b1), .led_state(led_state),
        .dfifo_cfg(dfifo_cfg), .dfifo_tlp(dfifo_tlp), .dfifo_pcie(dfifo_pcie),
        .dshadow2fifo(dshadow2fifo)
    );

    localparam integer NPIN = 9;
    wire [NPIN-1:0] pin = {
        dut.i_pcileech_req_np_cap.rst,
        dut.i_pcileech_req_gate_axis.rst,
        dut.i_pcileech_req_tx_obs.rst,
        dut.i_pcileech_req_table.rst,
        dut.i_pcileech_req_rx_cpl.rst,
        dut.i_pcileech_req_err.rst,
        dut.i_pcileech_req_status.rst_pcie,
        dut.i_pcileech_tlps128_src64.rst,
        dut.i_pcileech_tlps128_dst64.rst
    };
    function automatic string pin_name(input integer i);
        case (i)
            8: return "req_np_cap";   7: return "req_gate_axis"; 6: return "req_tx_obs";
            5: return "req_table";    4: return "req_rx_cpl";    3: return "req_err";
            2: return "req_status";   1: return "src64";         default: return "dst64";
        endcase
    endfunction

    integer errors = 0;
    task automatic fail(input string msg);
        errors = errors + 1;
        $display("A7_SCOPE_ERR t=%0t %s", $time, msg);
    endtask

    // Watch windows: phase A records any tracker pin high, phase B any pin seen.
    reg watch_leak = 1'b0, watch_seen = 1'b0;
    reg [NPIN-1:0] leaked = '0, seen = '0;
    integer subsys_rise = 0;
    reg subsys_q = 1'b0;
    always @(posedge clk_pcie) begin
        if (watch_leak) leaked <= leaked | pin;
        if (watch_seen) seen   <= seen   | pin;
        subsys_q <= dut.rst_subsys;
        if (watch_leak && dut.rst_subsys && !subsys_q) subsys_rise = subsys_rise + 1;
    end

    task automatic wait_sys(input integer n);
        repeat (n) @(posedge clk_sys);
    endtask

    integer k, waited;
    initial begin
        // power-up: global reset, then the link comes up
        wait_sys(200);
        rst = 1'b0;
        wait_sys(300);
        @(posedge clk_pcie) user_rst <= 1'b0;
        // settle: every reset released, including the post-reset sequences
        waited = 0;
        while ((pin != '0 || dut.rst_subsys || dut.rst_subsys_sys) && waited < 20000) begin
            wait_sys(1); waited = waited + 1;
        end
        if (pin != '0 || dut.rst_subsys) fail("resets not released after power-up");
        wait_sys(200);

        // ---- phase A: host subsystem resets on a live link ----------------------
        watch_leak = 1'b1;
        for (k = 0; k < 8; k = k + 1) begin
            host_soft = 1'b1;
            wait_sys(1 + 3 * k);
            host_soft = 1'b0;
            // the request must reach the clk_pcie subsystem reset and finish
            waited = 0;
            while ((dut.rst_subsys || dut.rst_subsys_sys || waited < 50) && waited < 20000) begin
                wait_sys(1); waited = waited + 1;
            end
            wait_sys(20 + 7 * k);
        end
        wait_sys(200);
        watch_leak = 1'b0;
        if (subsys_rise < 8)
            fail($sformatf("A7_SCOPE_NO_SUBSYS only %0d of 8 host requests reached rst_subsys", subsys_rise));
        for (k = 0; k < NPIN; k = k + 1)
            if (leaked[k]) fail({"A7_SCOPE_LEAK ", pin_name(k), " reset by a host subsystem reset"});

        // ---- phase B: positive control, core user reset --------------------------
        watch_seen = 1'b1;
        @(posedge clk_pcie) user_rst <= 1'b1;
        repeat (40) @(posedge clk_pcie);
        @(posedge clk_pcie) user_rst <= 1'b0;
        repeat (40) @(posedge clk_pcie);
        watch_seen = 1'b0;
        for (k = 0; k < NPIN; k = k + 1)
            if (!seen[k]) fail({"A7_SCOPE_MISSING ", pin_name(k), " not reset by the core user reset"});

        if (errors == 0) $display("R1_TB_PASS tb_a7_reset_scope subsys_resets=%0d pins=%0d", subsys_rise, NPIN);
        else             $display("R1_TB_FAIL tb_a7_reset_scope errors=%0d", errors);
        $finish;
    end

    initial begin
        #5ms;
        $display("R1_TB_FAIL tb_a7_reset_scope timeout");
        $finish;
    end
endmodule
