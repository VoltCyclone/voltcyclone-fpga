// R4 acceptance: beats past the TX mux at a host subsystem reset.
//
// Runs the production pcileech_pcie_a7 (reset generator, TX drain, req_gate,
// dst64) with the PCIe core, tlp_a7 and cfg_a7 replaced by stubs
// (run_a7_tx_beats.py builds them). The tlp_a7 stub holds the production TX
// mux (pcileech_tlps128_sink_mux1) fed by four packet sources (tb_tx_src);
// mux and sources reset on rst_subsys, as in production. The core stub drives
// s_axis_tx_tready from this bench, with stalls aimed at each host request.
//
// A host subsystem reset on a live link stops the mux at a packet boundary,
// then resets the mux and sources; req_gate and dst64 are not reset, so a
// packet already past the mux must reach the core whole, exactly once, in
// order, whatever the core's ready does. Markers (R1_TB_FAIL on any):
//   A7_TX_CUT      a packet at the core is not one whole source packet
//   A7_TX_ORDER    a whole packet arrives out of order or was never sent
//   A7_TX_LOST     a packet that left the mux never reached the core
//   A7_TX_MUX_CUT  rst_subsys rose while a packet was open at the mux output
//   A7_TX_UNSTABLE the core's input changed while valid && !ready
//   A7_TX_COVERAGE too few resets with beats held past the mux
`timescale 1ns / 1ps
`include "pcileech_header.svh"

// Pull-protocol packet source: tready in one clock returns one beat in the
// next. has_data means a whole packet is waiting beyond any open one.
// Packet: 3-DW header, DW1[31:16] = id, data DW i = {id, i}; kind 0 MWr,
// 1 CplD, 2 MRd with a foreign requester ID (the gate refuses and drops it).
module tb_tx_src #(parameter integer ID = 1) (
    input clk, rst,
    IfAXIS128.source o
);
    reg         valid = 1'b0, last = 1'b0, first = 1'b0;
    reg [127:0] data = '0;
    reg [3:0]   keep = '0;
    reg         open = 1'b0;
    reg [15:0]  id = '0;
    reg [1:0]   kind = '0;
    reg [9:0]   len = '0;
    reg [11:0]  dw = '0;            // next DW index of the open packet
    reg [13:0]  seq = '0;
    integer     pending = 0;
    assign o.tdata = data; assign o.tkeepdw = keep; assign o.tvalid = valid;
    assign o.tlast = last; assign o.tuser = {7'd0, last, first};
    assign o.has_data = (pending > 0);

    function automatic [31:0] dword(input [15:0] pid, input [1:0] k, input [9:0] l, input [11:0] i);
        if (i == 0)      dword = (k == 0) ? {3'b010, 5'b00000, 14'd0, l} :
                                 (k == 1) ? {3'b010, 5'b01010, 14'd0, l} :
                                            {3'b000, 5'b00000, 14'd0, 10'd1};
        else if (i == 1) dword = (k == 2) ? {16'hfeed, 8'h00, 8'h0f} : {pid, 8'h00, 8'h0f};
        else if (i == 2) dword = {pid, 16'h0040};
        else             dword = {pid, 4'h0, 12'(i - 3)};
    endfunction

    integer b;
    reg [11:0] total;
    always @(posedge clk) begin
        if (rst) begin
            valid <= 1'b0; open = 1'b0; pending = 0;
        end else begin
            if (tb_a7_tx_beats.gen_en && pending < 3 && ($urandom % 6) == 0)
                pending = pending + 1;
            valid <= 1'b0;
            if (o.tready) begin
                if (!open) begin
                    if (pending == 0) $display("R1_TB_FAIL A7_TX_SRC pulled with nothing to send (src %0d)", ID);
                    pending = pending - 1;
                    seq = seq + 14'd1;
                    id = {2'(ID - 1), seq};
                    case ($urandom % 10)
                        0:       begin kind = 2'd2; len = 10'd1; end
                        1,2,3:   begin kind = 2'd1; len = 10'(1 + $urandom % 32); end
                        default: begin kind = 2'd0; len = 10'(1 + $urandom % 40); end
                    endcase
                    dw = '0; open = 1'b1;
                end
                total = (kind == 2) ? 12'd3 : 12'd3 + 12'(len);
                first <= (dw == 0);
                for (b = 0; b < 4; b = b + 1) begin
                    data[32*b +: 32] <= (dw + 12'(b) < total) ? dword(id, kind, len, dw + 12'(b)) : 32'h0;
                    keep[b]          <= (dw + 12'(b) < total);
                end
                last  <= (dw + 12'd4 >= total);
                valid <= 1'b1;
                if (dw + 12'd4 >= total) open = 1'b0;
                dw = dw + 12'd4;
            end
        end
    end
endmodule

module tb_a7_tx_beats;
    reg clk_sys = 1'b0, clk_pcie = 1'b0;
    always #5 clk_sys = ~clk_sys;           // 100 MHz
    always #8 clk_pcie = ~clk_pcie;         // 62.5 MHz core user clock
    reg rst = 1'b1, user_rst = 1'b1, host_soft = 1'b0;
    reg gen_en = 1'b0;
    reg core_ready = 1'b0;

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

    integer errors = 0;
    task automatic fail(input string msg);
        errors = errors + 1;
        if (errors <= 20) $display("A7_TX_ERR t=%0t %s", $time, msg);
    endtask

    // ---- expected: whole non-MRd packets in mux output order --------------------
    reg [15:0] exp_q[$];
    reg        mux_open = 1'b0;
    reg [15:0] mux_id;
    reg [1:0]  mux_kind;
    integer    sent = 0, refused = 0;
    always @(posedge clk_pcie) begin
        if (dut.rst_subsys && mux_open) begin
            fail("A7_TX_MUX_CUT subsystem reset with a packet open at the mux output");
            mux_open <= 1'b0;
        end else if (dut.tlps_tx.tvalid) begin
            if (dut.tlps_tx.tuser[0]) begin
                mux_id   = dut.tlps_tx.tdata[63:48];
                mux_kind = (dut.tlps_tx.tdata[31:29] == 3'b000) ? 2'd2 :
                           (dut.tlps_tx.tdata[28:24] == 5'b01010) ? 2'd1 : 2'd0;
                if (mux_open) fail("A7_TX_MUX_CUT a packet started before the previous one ended");
            end
            mux_open <= !dut.tlps_tx.tlast;
            if (dut.tlps_tx.tlast && mux_kind == 2'd2) refused = refused + 1;
            if (dut.tlps_tx.tlast && mux_kind != 2'd2) begin
                exp_q.push_back(mux_id);
                sent = sent + 1;
            end
        end
    end

    // ---- core: reassemble, check, compare with expected ------------------------
    wire        c_valid = dut.i_pcie_7x_0.s_axis_tx_tvalid;
    wire [63:0] c_data  = dut.i_pcie_7x_0.s_axis_tx_tdata;
    wire [7:0]  c_keep  = dut.i_pcie_7x_0.s_axis_tx_tkeep;
    wire        c_last  = dut.i_pcie_7x_0.s_axis_tx_tlast;
    reg  [31:0] dws[$];
    reg         stalled = 1'b0;
    reg  [73:0] stalled_word;
    integer     received = 0, n, i;
    reg  [15:0] pid;
    reg         ok;
    always @(posedge clk_pcie) begin
        if (stalled && !dut.i_pcileech_tlps128_dst64.rst &&
            (!c_valid || {c_data, c_keep, c_last} != stalled_word[72:0]))
            fail("A7_TX_UNSTABLE core input changed while stalled");
        stalled      <= c_valid && !core_ready;
        stalled_word <= {1'b0, c_data, c_keep, c_last};
        if (c_valid && core_ready) begin
            dws.push_back(c_data[31:0]);
            if (c_keep == 8'hff) dws.push_back(c_data[63:32]);
            else if (c_keep != 8'h0f) fail($sformatf("A7_TX_CUT keep %h", c_keep));
            if (c_last) begin
                ok = (dws.size() >= 3) && dws[0][31:29] == 3'b010 &&
                     (dws[0][28:24] == 5'b00000 || dws[0][28:24] == 5'b01010);
                n  = ok ? 3 + ((dws[0][9:0] == 0) ? 1024 : dws[0][9:0]) : 0;
                ok = ok && dws.size() == n;
                pid = (dws.size() >= 2) ? dws[1][31:16] : 16'h0;
                if (ok) for (i = 3; i < n; i = i + 1)
                    if (dws[i] != {pid, 4'h0, 12'(i - 3)}) ok = 1'b0;
                if (ok && dws[2] != {pid, 16'h0040}) ok = 1'b0;
                if (!ok)
                    fail($sformatf("A7_TX_CUT packet of %0d DWs (DW0 %h DW1 %h) is not one whole source packet",
                                   dws.size(), dws[0], (dws.size() >= 2) ? dws[1] : 32'h0));
                else if (exp_q.size() == 0 || exp_q[0] != pid)
                    fail($sformatf("A7_TX_ORDER packet %h, expected %h", pid,
                                   (exp_q.size() != 0) ? exp_q[0] : 16'hxxxx));
                else begin
                    void'(exp_q.pop_front());
                    received = received + 1;
                end
                dws.delete();
            end
        end
    end

    // ---- core ready: random, with a stall aimed at each host request -----------
    integer stall = 0;
    reg host_q = 1'b0;
    always @(posedge clk_pcie) begin
        host_q <= host_soft;
        if (host_soft && !host_q) stall = $urandom % 120;
        else if (stall == 0 && ($urandom % 200) == 0) stall = $urandom % 60;
        if (stall > 0) begin stall = stall - 1; core_ready <= 1'b0; end
        else core_ready <= gen_en ? (($urandom % 4) != 0) : 1'b1;
    end

    // ---- occupancy past the mux at each reset ----------------------------------
    integer resets = 0, busy_resets = 0, held_beats = 0, h;
    reg subsys_q = 1'b0;
    always @(posedge clk_pcie) begin
        subsys_q <= dut.rst_subsys;
        if (dut.rst_subsys && !subsys_q && gen_en) begin
            resets = resets + 1;
            h = dut.i_pcileech_req_gate_axis.i_gate.q_count +
                dut.i_pcileech_req_gate_axis.i_gate.s_valid +
                dut.i_pcileech_tlps128_dst64.q_count;
            if (h != 0) begin busy_resets = busy_resets + 1; held_beats = held_beats + h; end
        end
    end

    task automatic wait_sys(input integer n);
        repeat (n) @(posedge clk_sys);
    endtask

    integer k, waited, r0, pulse;
    localparam integer NRESET = 200;
    initial begin
        wait_sys(200);
        rst = 1'b0;
        wait_sys(300);
        @(posedge clk_pcie) user_rst <= 1'b0;
        waited = 0;
        while ((dut.rst_subsys || dut.rst_subsys_sys || dut.i_pcileech_tlps128_dst64.rst) && waited < 20000) begin
            wait_sys(1); waited = waited + 1;
        end
        wait_sys(200);
        gen_en = 1'b1;
        for (k = 0; k < NRESET; k = k + 1) begin
            wait_sys(150 + $urandom % 1500);
            r0 = resets;
            pulse = 1 + $urandom % 40;
            host_soft = 1'b1;
            wait_sys(pulse);
            host_soft = 1'b0;
            // each request must reach rst_subsys once the core has taken
            // enough to let the mux finish its packet, then release
            waited = 0;
            while ((resets == r0 || dut.rst_subsys || dut.rst_subsys_sys) && waited < 20000) begin
                wait_sys(1); waited = waited + 1;
            end
            if (resets != r0 + 1)
                fail($sformatf("A7_TX_NO_RESET request %0d (pulse %0d) gave %0d subsystem resets, drain state %0d",
                               k, pulse, resets - r0, dut.i_pcileech_pcie_tx_drain.state));
        end
        // drain: no new packets, core ready
        wait_sys(500);
        gen_en = 1'b0;
        wait_sys(20000);
        if (exp_q.size() != 0)
            fail($sformatf("A7_TX_LOST %0d packets left the mux and never reached the core (first %h)",
                           exp_q.size(), exp_q[0]));
        if (resets < NRESET || busy_resets < NRESET / 4 || received < 1000 || refused < 50)
            fail($sformatf("A7_TX_COVERAGE resets=%0d busy=%0d received=%0d refused=%0d", resets, busy_resets, received, refused));
        if (errors == 0)
            $display("R1_TB_PASS tb_a7_tx_beats resets=%0d busy_resets=%0d held_beats=%0d sent=%0d received=%0d refused_mrd=%0d",
                     resets, busy_resets, held_beats, sent, received, refused);
        else
            $display("R1_TB_FAIL tb_a7_tx_beats errors=%0d resets=%0d busy=%0d sent=%0d received=%0d",
                     errors, resets, busy_resets, sent, received);
        $finish;
    end

    initial begin
        #50ms;
        $display("R1_TB_FAIL tb_a7_tx_beats timeout");
        $finish;
    end
endmodule
