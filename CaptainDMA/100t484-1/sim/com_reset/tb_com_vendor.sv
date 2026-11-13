`timescale 1ns/1ps
`include "pcileech_header.svh"

// Exercise production COM/XPM/FIFO wiring. Stimulus is injected at the
// clock-controller and PHY stream boundaries; electrical/PHY behavior is out
// of scope. No FIFO or XPM implementation is replaced.
module tb_com_vendor;
    reg clk = 0, cclk = 0;
    reg sys_run = 1, com_run = 1;
    reg rst = 1, not_ready = 1;
    reg [31:0] rx_data = 0;
    reg rx_valid = 0, tx_pull = 0;
    reg [255:0] tx_data = 0;
    reg tx_write = 0;
    real sys_half = 5.0, com_half = 5.0, phase = 1.3;
    integer scenario = 0;
    integer rx_seen = 0, tx_seen = 0, episodes = 0;
    bit score = 0;
    reg [63:0] rx_expected[$];
    reg [31:0] tx_expected[$];
    reg [63:0] rx_want;
    reg [31:0] tx_want;
    wire [31:0] pads;
    wire [3:0] be;
    wire wr_n, rd_n, oe_n, siwu_n;
    IfComToFifo bus();
    assign bus.com_din = tx_data;
    assign bus.com_din_wr_en = tx_write;

    pcileech_com dut (
        .clk(clk), .clk_com(cclk), .rst(rst), .dfifo(bus),
        .led_state_txdata(), .led_state_invert(1'b0),
        .ft601_data(pads), .ft601_be(be),
        .ft601_rxf_n(1'b1), .ft601_txe_n(1'b1),
        .ft601_wr_n(wr_n), .ft601_siwu_n(siwu_n),
        .ft601_rd_n(rd_n), .ft601_oe_n(oe_n)
    );

    initial begin
        if ($value$plusargs("SYS_HALF=%f", sys_half)) begin end
        forever begin #(sys_half); if (sys_run) clk = ~clk; else clk = 0; end
    end
    initial begin
        if ($value$plusargs("COM_HALF=%f", com_half)) begin end
        if ($value$plusargs("PHASE=%f", phase)) begin end
        #(phase);
        forever begin #(com_half); if (com_run) cclk = ~cclk; else cclk = 0; end
    end
    initial begin
        force dut.clk_c = cclk;
        force dut.com_arst = not_ready;
        force dut.com_rx_data32 = rx_data;
        force dut.com_rx_valid32 = rx_valid;
        force dut.core_din_ready = tx_pull;
    end

    // Model outputs have a documented 100 ps input delay. Sample after NBA
    // and model propagation, away from the next clock edge.
    always @(posedge clk) begin
        #1;
        if (score && bus.com_dout_valid) begin
            if (rx_expected.size() == 0)
                $fatal(1, "COM_RX_UNEXPECTED data=%h episode=%0d", bus.com_dout, episodes);
            rx_want = rx_expected.pop_front();
            if (bus.com_dout !== rx_want)
                $fatal(1, "COM_RX_ORDER want=%h got=%h", rx_want, bus.com_dout);
            rx_seen = rx_seen + 1;
        end
    end
    always @(posedge cclk) begin
        #1;
        if (score && dut.core_din_wr_en) begin
            if (tx_expected.size() == 0)
                $fatal(1, "COM_TX_UNEXPECTED data=%h episode=%0d", dut.core_din, episodes);
            tx_want = tx_expected.pop_front();
            if (dut.core_din !== tx_want)
                $fatal(1, "COM_TX_ORDER want=%h got=%h", tx_want, dut.core_din);
            tx_seen = tx_seen + 1;
        end
    end

    task automatic rx_word(input reg [31:0] word_data);
        @(negedge cclk); rx_data = word_data; rx_valid = 1;
        @(negedge cclk); rx_valid = 0;
    endtask
    task automatic rx_pair(input reg [31:0] first, second);
        rx_expected.push_back({first, second});
        rx_word(first);
        rx_word(second);
    endtask
    task automatic tx_bundle(input reg [31:0] base);
        reg [255:0] word_data;
        integer n;
        for (n = 0; n < 8; n = n + 1) begin
            // PG057 non-symmetric FIFO ordering: the high slice is read first.
            word_data[255-n*32 -: 32] = base + n;
            tx_expected.push_back(base + n);
        end
        @(negedge clk);
        while (bus.com_din_ready !== 1'b1) @(negedge clk);
        tx_data = word_data; tx_write = 1;
        @(negedge clk); tx_write = 0;
    endtask
    task automatic drained;
        wait (rx_expected.size() == 0 && tx_expected.size() == 0);
        repeat (30) @(negedge clk);
        repeat (30) @(negedge cclk);
    endtask
    task automatic healthy(input integer epoch);
        integer n;
        tx_pull = 1;
        for (n = 0; n < 8; n = n + 1) begin
            rx_pair(32'h81000000 + epoch*256 + n*2,
                    32'h81000001 + epoch*256 + n*2);
            tx_bundle(32'h92000000 + epoch*256 + n*8);
        end
        drained();
        $display("COM_HEALTHY epoch=%0d rx=%0d tx=%0d", epoch, rx_seen, tx_seen);
    endtask
    task automatic reset_episode(input integer kind);
        // Queue old-session TX words and leave one unpaired RX word. For
        // stopped SYS also queue an old RX pair so an omitted FIFO reset
        // must expose stale data when SYS resumes.
        tx_pull = 0;
        tx_bundle(32'hA3000000 + episodes*256);
        rx_word(32'hB4000000 + episodes);
        if (kind == 2) begin
            @(negedge clk); sys_run = 0;
            rx_word(32'hB5000000 + episodes);
        end
        if (kind == 1) begin
            @(negedge cclk); com_run = 0;
        end
        #2.1; not_ready = 1;
        // Explicit COM session abort: only these queued old-session words
        // may be discarded. The post-reset scoreboard remains enabled.
        rx_expected.delete(); tx_expected.delete();
        episodes = episodes + 1;
        #150;
        if (kind == 1 && bus.com_din_ready !== 1'b0)
            $fatal(1, "COM_READY_WITH_STOPPED_READ_CLOCK");
        sys_run = 1; com_run = 1;
        repeat (20) @(negedge clk);
        repeat (20) @(negedge cclk);
        #2.1; not_ready = 0;
        // Offer new TX traffic on the first advertised-ready cycle, rather
        // than allowing a generous settling delay to hide early admission.
        tx_pull = 1;
        tx_bundle(32'hC6000000 + episodes*256);
        repeat (40) @(negedge clk);
        repeat (40) @(negedge cclk);
        if (bus.com_din_ready !== 1'b1)
            $fatal(1, "COM_NO_RECOVERY");
        tx_pull = 1;
        repeat (30) @(negedge cclk);
        healthy(episodes);
    endtask

    initial begin
        if ($value$plusargs("CASE=%d", scenario)) begin end
        #300.2; rst = 0; not_ready = 0;
        repeat (100) @(negedge clk);
        repeat (100) @(negedge cclk);
        // Initial built-in configuration commands have completed; COM-only
        // reset episodes below never restart that SYS-domain sequence.
        score = 1;
        healthy(0);
        reset_episode(scenario);
        reset_episode(scenario);
        if (rx_seen != 24 || tx_seen != 208)
            $fatal(1, "COM_COUNTS rx=%0d tx=%0d", rx_seen, tx_seen);
        $display("COM_VENDOR_PASS case=%0d episodes=%0d rx=%0d tx=%0d",
                 scenario, episodes, rx_seen, tx_seen);
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "COM_VENDOR_TIMEOUT rx_pending=%0d tx_pending=%0d",
               rx_expected.size(), tx_expected.size());
    end
endmodule
