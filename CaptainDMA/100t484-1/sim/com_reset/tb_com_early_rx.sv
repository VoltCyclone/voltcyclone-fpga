`timescale 1ns/1ps
`include "pcileech_header.svh"

// Pin-driven earliest RX through the real PHY, packer, XPMs and vendor FIFOs.
// Only MMCM clock/status outputs are forced: ideal c0/c180 at +0.5/+5.5 ns.
module tb_com_early_rx;
    reg clk = 0, e = 0, c0 = 0, c180 = 0;
    reg run_e = 1;
    reg rst = 1, not_ready = 1, model_rst = 1;
    real sys_half = 5.0, phase = 1.3, release_delay = 0.2;
    integer scenario = 0, epoch = -1;
    integer rx_seen = 0, physical_reads = 0, first_write = 0;
    bit score = 0;
    reg [63:0] expected[$];
    reg [63:0] want;
    wire [31:0] data;
    wire [3:0] be;
    wire rxf_n, txe_n, oe_n, rd_n, wr_n, siwu_n;
    wire [35:0] fpga_bus;
    IfComToFifo bus();
    assign bus.com_din = 256'b0;
    assign bus.com_din_wr_en = 1'b0;

    initial begin
        if ($value$plusargs("SYS_HALF=%f", sys_half)) begin end
        forever #(sys_half) clk = ~clk;
    end
    initial begin
        if ($value$plusargs("PHASE=%f", phase)) begin end
        #(phase);
        forever begin #5; if (run_e) e = ~e; end
    end
    always @(e) begin c0 <= #0.5 e; c180 <= #5.5 e; end

    pcileech_com dut (
        .clk(clk), .clk_com(e), .rst(rst), .dfifo(bus),
        .led_state_txdata(), .led_state_invert(1'b0),
        .ft601_data(data), .ft601_be(be),
        .ft601_rxf_n(rxf_n), .ft601_txe_n(txe_n),
        .ft601_wr_n(wr_n), .ft601_siwu_n(siwu_n),
        .ft601_rd_n(rd_n), .ft601_oe_n(oe_n)
    );
    initial begin
        force dut.clk_c = c0;
        force dut.ft601_c180 = c180;
        force dut.com_arst = not_ready;
    end
    genvar i;
    generate
        for (i = 0; i < 32; i = i + 1) begin : mon_data
            assign fpga_bus[i] = dut.g_ft601_phy.i_pcileech_ft601_phy.g_data[i].q_t
                ? 1'bz : dut.g_ft601_phy.i_pcileech_ft601_phy.g_data[i].q_o;
        end
        for (i = 0; i < 4; i = i + 1) begin : mon_be
            assign fpga_bus[32+i] = dut.g_ft601_phy.i_pcileech_ft601_phy.g_be[i].q_t
                ? 1'bz : 1'b1;
        end
    endgenerate
    ft601_model #(.TCO_MIN(3.5), .TCO_MAX(7.0), .T_HIZ(6.0)) m (
        .clk(e), .data(data), .be(be), .rxf_n(rxf_n), .txe_n(txe_n),
        .oe_n(oe_n), .rd_n(rd_n), .wr_n(wr_n), .model_rst(model_rst),
        .fpga_bus(fpga_bus)
    );

    // Physical bus words 11223300, 11223301 become 00332211_01332211.
    function automatic [31:0] expected_word(input integer index);
        expected_word = {8'(index), 24'h332211};
    endfunction
    always @(posedge clk) begin
        #1;
        if (score && bus.com_dout_valid) begin
            if (expected.size() == 0) $fatal(1, "COM_EARLY_EXTRA %h", bus.com_dout);
            want = expected.pop_front();
            if (bus.com_dout !== want)
                $fatal(1, "COM_EARLY_ORDER epoch=%0d want=%h got=%h", epoch, want, bus.com_dout);
            rx_seen = rx_seen + 1;
        end
    end
    always @(posedge e)
        if (score && !rxf_n && !rd_n) begin
            if (physical_reads % 32 == 0)
                $display("COM_EARLY_FIRST_PIN epoch=%0d time=%0t", epoch, $realtime);
            physical_reads = physical_reads + 1;
        end
    always @(negedge dut.rst_com)
        if (score) $display("COM_EARLY_COM_RESET_RELEASE epoch=%0d time=%0t", epoch, $realtime);
    always @(negedge dut.g_ft601_phy.rst_phy)
        if (score) $display("COM_EARLY_PHY_RESET_RELEASE epoch=%0d time=%0t", epoch, $realtime);
    always @(negedge dut.rst_comrx_fifo)
        if (score) $display("COM_EARLY_FIFO_RESET_RELEASE epoch=%0d time=%0t", epoch, $realtime);
    always @(negedge dut.i_fifo_64_64_clk2_comrx.full)
        if (score) $display("COM_EARLY_FIFO_WR_READY epoch=%0d time=%0t", epoch, $realtime);
    always @(posedge c0)
        if (score && dut.com_rx_valid64) begin
            if (dut.i_fifo_64_64_clk2_comrx.full !== 1'b0)
                $fatal(1, "COM_EARLY_FIFO_NOT_READY epoch=%0d reset=%b full=%b", epoch,
                       dut.rst_comrx_fifo, dut.i_fifo_64_64_clk2_comrx.full);
            if (!first_write) begin
                first_write = 1;
                $display("COM_EARLY_FIRST_FIFO_WRITE epoch=%0d time=%0t", epoch, $realtime);
            end
        end

    task automatic waiting_rx;
        integer n;
        for (n = 0; n < 32; n = n + 1) m.push_rx(32'h11223300 + epoch*32 + n);
        for (n = 0; n < 16; n = n + 1)
            expected.push_back({expected_word(epoch*32+n*2), expected_word(epoch*32+n*2+1)});
        m.open_rx(32);
    endtask
    task automatic release_and_check;
        // RXF_N is already low before release. There is no settling interval
        // between synchronized PHY reset release and the first device words.
        repeat (3) @(negedge e);
        #(release_delay); not_ready = 0;
        wait (rx_seen == (epoch+1)*16);
        repeat (40) @(negedge e);
        if (m.rx_xfers != (epoch+1)*32 || physical_reads != (epoch+1)*32 || m.err != 0)
            $fatal(1, "COM_EARLY_MODEL_COUNTS model=%0d pins=%0d err=%0d",
                   m.rx_xfers, physical_reads, m.err);
        // A full condition during an established session is backpressure,
        // not permission to reset the PHY and clear its replay/history state.
        force dut.com_rx_full = 1'b1;
        repeat (3) @(negedge c0);
        if (dut.g_ft601_phy.rst_phy !== 1'b0)
            $fatal(1, "COM_EARLY_LIVE_FULL_RESET");
        release dut.com_rx_full;
        $display("COM_EARLY_EPOCH_PASS epoch=%0d pairs=%0d", epoch, rx_seen);
    endtask

    initial begin
        if ($value$plusargs("CASE=%d", scenario)) begin end
        case (scenario)
            0: release_delay = 0.2;
            1: release_delay = 4.9;
            2: release_delay = 5.2;
            default: $fatal(1, "COM_EARLY_BAD_CASE");
        endcase
        m.tx_block = 1;
        #300.2; rst = 0; model_rst = 0;
        // Allow only the separate SYS boot-command stream to finish.
        // The PHY and COM FIFOs remain held in reset throughout this wait.
        repeat (100) @(negedge clk);
        score = 1;
        epoch = 0; first_write = 0;
        waiting_rx(); release_and_check();

        @(negedge e); #1.2; not_ready = 1;
        epoch = 1; first_write = 0;
        repeat (20) @(negedge e);
        waiting_rx(); release_and_check();

        @(negedge e); run_e = 0;
        #10; not_ready = 1;
        epoch = 2; first_write = 0;
        #150; run_e = 1;
        repeat (20) @(negedge e);
        waiting_rx(); release_and_check();
        if (expected.size() != 0 || rx_seen != 48 || physical_reads != 96)
            $fatal(1, "COM_EARLY_COUNTS pairs=%0d pins=%0d", rx_seen, physical_reads);
        $display("COM_EARLY_PASS case=%0d epochs=3 pairs=48 pins=96", scenario);
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "COM_EARLY_TIMEOUT pairs=%0d pins=%0d pending=%0d",
               rx_seen, physical_reads, expected.size());
    end
endmodule
