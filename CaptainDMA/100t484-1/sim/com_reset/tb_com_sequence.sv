`timescale 1ns/1ps
`include "pcileech_header.svh"
// Real clock-controller state machine; only ideal MMCM clocks/status are modeled.
module tb_com_sequence;
    reg clk=0, eclk=0, c0=0, c180=0;
    reg e_run=0, fault=0, rst=1;
    real sys_half=5.0, phase=1.3;
    integer scenario=0, epochs=0, rx_edges=0, tx_edges=0;
    integer sys_edges=0, com_edges=0, rx_last_sys=0, rx_last_com=0;
    integer tx_last_sys=0, tx_last_com=0;
    bit rx_observed=0, tx_observed=0;
    realtime rx_last_time=0, tx_last_time=0;
    reg [31:0] rx_data=0;
    reg rx_valid=0, user_write=0;
    reg [255:0] user_data=0;
    reg [63:0] rx_expected[$];
    reg [31:0] tx_expected[$];
    reg [63:0] rx_want;
    reg [31:0] tx_want;
    bit score=0;
    integer rx_seen=0, tx_seen=0, target;
    wire [31:0] pads;
    localparam [31:0] STATUS = 32'h333333E3;
    function automatic bit is_idle(input [31:0] d);
        return d == 32'hFFFFFFEF || d == 32'hFFFFFFFF;
    endfunction
    IfComToFifo bus();
    assign bus.com_din=user_data;
    // Deliberately hold a stale offer during quarantine; DUT must suppress it.
    assign bus.com_din_wr_en=user_write || rst || dut.com_arst;
    pcileech_com dut(.clk(clk), .clk_com(eclk), .rst(rst), .dfifo(bus),
        .led_state_txdata(), .led_state_invert(1'b0), .ft601_data(pads),
        .ft601_be(), .ft601_rxf_n(1'b1), .ft601_txe_n(1'b1),
        .ft601_wr_n(), .ft601_siwu_n(), .ft601_rd_n(), .ft601_oe_n());
    wire model_lock=e_run && !fault && !dut.g_ft601_mmcm_clk.i_ft601_clk.mmcm_rst;
    initial begin
        if ($value$plusargs("SYS_HALF=%f",sys_half)) begin end
        forever #(sys_half) clk=~clk;
    end
    initial begin
        if ($value$plusargs("PHASE=%f",phase)) begin end
        #(phase);
        forever begin #5; if(e_run) eclk=~eclk; else eclk=0; end
    end
    always @(eclk) begin c0 <= #0.5 eclk; c180 <= #5.5 eclk; end
    initial begin
        force dut.com_rx_data32=rx_data;
        force dut.com_rx_valid32=rx_valid;
        force dut.core_din_ready=1'b1;
        force dut.clk_c=c0;
        force dut.ft601_c180=c180;
        force dut.g_ft601_mmcm_clk.i_ft601_clk.mmcm_locked=model_lock;
        force dut.g_ft601_mmcm_clk.i_ft601_clk.mmcm_clkinstopped=!e_run;
    end
    // Count only periods with controller-certified clocks. At each loss all
    // credit is revoked, including a reset assertion concurrent with loss.
    always @(posedge clk) if (!dut.com_arst && !rst) sys_edges=sys_edges+1;
    always @(posedge c0) if (!dut.com_arst && !rst) com_edges=com_edges+1;
    always @(posedge dut.com_arst) begin
        rx_edges=0; tx_edges=0; rx_observed=0; tx_observed=0;
    end
    always @(negedge dut.com_arst) begin
        #0.01;
        rx_observed=1; tx_observed=1;
        rx_last_time=$realtime; tx_last_time=$realtime;
        rx_last_sys=sys_edges; rx_last_com=com_edges;
        tx_last_sys=sys_edges; tx_last_com=com_edges;
    end
    always @(dut.rst_comrx_fifo) begin
        #0.01;
        if (!dut.com_arst && !rst) begin
            if (rx_observed && (sys_edges-rx_last_sys<6 || com_edges-rx_last_com<6 ||
                $realtime-rx_last_time < 12*sys_half || $realtime-rx_last_time < 60))
                $fatal(1,"COM_SEQ_GAP_TOO_SHORT RX level=%b sys=%0d com=%0d",
                    dut.rst_comrx_fifo,sys_edges-rx_last_sys,com_edges-rx_last_com);
            $display("COM_SEQ_RESET_EDGE RX level=%b sys=%0d com=%0d ns=%0.3f",
                dut.rst_comrx_fifo,sys_edges-rx_last_sys,com_edges-rx_last_com,$realtime-rx_last_time);
            rx_observed=1; rx_last_sys=sys_edges; rx_last_com=com_edges; rx_last_time=$realtime;
            if(dut.rst_comrx_fifo) rx_edges=rx_edges+1;
        end
    end
    always @(dut.rst_comtx_fifo) begin
        #0.01;
        if (!dut.com_arst && !rst) begin
            if (tx_observed && (sys_edges-tx_last_sys<6 || com_edges-tx_last_com<6 ||
                $realtime-tx_last_time < 12*sys_half || $realtime-tx_last_time < 60))
                $fatal(1,"COM_SEQ_GAP_TOO_SHORT TX level=%b sys=%0d com=%0d",
                    dut.rst_comtx_fifo,sys_edges-tx_last_sys,com_edges-tx_last_com);
            $display("COM_SEQ_RESET_EDGE TX level=%b sys=%0d com=%0d ns=%0.3f",
                dut.rst_comtx_fifo,sys_edges-tx_last_sys,com_edges-tx_last_com,$realtime-tx_last_time);
            tx_observed=1; tx_last_sys=sys_edges; tx_last_com=com_edges; tx_last_time=$realtime;
            if(dut.rst_comtx_fifo) tx_edges=tx_edges+1;
        end
    end
    always @(negedge clk) begin
        #0.02;
        if ((dut.fifo_run_sys || bus.com_din_ready) && (rst || dut.com_arst || rx_edges<1 || tx_edges<1 ||
                                dut.rst_comrx_fifo || dut.rst_comtx_fifo))
            $fatal(1,"COM_SEQ_EARLY_READY");
        if (!dut.initial_rx_valid && bus.com_dout_valid &&
            (rst || dut.com_arst || rx_edges<1 || dut.rst_comrx_fifo))
            $fatal(1,"COM_SEQ_RX_VISIBLE_QUARANTINE");
        if ((rst || dut.com_arst || tx_edges<1 || dut.rst_comtx_fifo) &&
            dut.i_fifo_256_32_clk2_comtx.wr_en)
            $fatal(1,"COM_SEQ_TX_ENABLE_QUARANTINE");
        if ((rst || dut.com_arst || rx_edges<1 || dut.rst_comrx_fifo) &&
            dut.i_fifo_64_64_clk2_comrx.rd_en)
            $fatal(1,"COM_SEQ_RX_ENABLE_QUARANTINE");
        // Post-release hold: no FIFO enable or advertised readiness until six
        // full periods in BOTH clocks have elapsed since the reset fell.
        if ((dut.fifo_run_sys || bus.com_din_ready ||
             dut.i_fifo_256_32_clk2_comtx.wr_en || dut.i_fifo_64_64_clk2_comrx.rd_en) &&
            (sys_edges-rx_last_sys<6 || com_edges-rx_last_com<6 ||
             sys_edges-tx_last_sys<6 || com_edges-tx_last_com<6))
            $fatal(1,"COM_SEQ_ENABLE_TOO_EARLY sys=%0d com=%0d",
                sys_edges-rx_last_sys,com_edges-rx_last_com);
    end
    always @(negedge c0) begin
        #0.02;
        if ((dut.rst_com || rx_edges<1 || dut.rst_comrx_fifo) &&
            dut.i_fifo_64_64_clk2_comrx.wr_en)
            $fatal(1,"COM_SEQ_RX_ENABLE_QUARANTINE");
        if ((dut.rst_com || tx_edges<1 || dut.rst_comtx_fifo) &&
            dut.i_fifo_256_32_clk2_comtx.rd_en)
            $fatal(1,"COM_SEQ_TX_ENABLE_QUARANTINE");
        if ((dut.i_fifo_64_64_clk2_comrx.wr_en || dut.i_fifo_256_32_clk2_comtx.rd_en) &&
            (sys_edges-rx_last_sys<6 || com_edges-rx_last_com<6 ||
             sys_edges-tx_last_sys<6 || com_edges-tx_last_com<6))
            $fatal(1,"COM_SEQ_ENABLE_TOO_EARLY sys=%0d com=%0d",
                sys_edges-rx_last_sys,com_edges-rx_last_com);
    end
    always @(posedge clk) begin
        #1;
        if(score && bus.com_dout_valid && !dut.initial_rx_valid) begin
            if(rx_expected.size()==0) $fatal(1,"COM_SEQ_RX_EXTRA");
            rx_want=rx_expected.pop_front();
            if(bus.com_dout !== rx_want) $fatal(1,"COM_SEQ_RX_ORDER");
            rx_seen=rx_seen+1;
        end
    end
    always @(posedge c0) begin
        #1;
        // Idle words written after each TX flush are checked by tb_com_tx_session.
        if(score && dut.core_din_wr_en && !is_idle(dut.core_din)) begin
            if(tx_expected.size()==0) $fatal(1,"COM_SEQ_TX_EXTRA");
            tx_want=tx_expected.pop_front();
            if(dut.core_din !== tx_want) $fatal(1,"COM_SEQ_TX_ORDER");
            tx_seen=tx_seen+1;
        end
    end
    // Match the sequencer's sampled invalidation boundary: a transition on
    // the same SYS edge as newly asserted controller status is interrupted,
    // while status already high at the sampling edge must freeze the pin.
    always @(posedge clk) begin : check_frozen_reset
        reg old_rx, old_tx;
        if(rst || dut.com_arst) begin
            old_rx=dut.rst_comrx_fifo; old_tx=dut.rst_comtx_fifo;
            #0.03;
            if(dut.rst_comrx_fifo !== old_rx || dut.rst_comtx_fifo !== old_tx)
                $fatal(1,"COM_SEQ_RESET_NOT_FROZEN");
        end
    end
    // rx_ready and the sequencer's stale-ack argument rely on the real
    // controller raising com_arst on the SYS edge after every rst.
    reg rst_q=0;
    always @(posedge clk) begin
        if(rst_q && !dut.com_arst) $fatal(1,"COM_RST_WITHOUT_ARST");
        rst_q <= rst;
    end
    task automatic healthy;
        integer n;
        reg [31:0] base;
        base=32'h81000000+epochs*256;
        score=1;
        rx_expected.push_back({base,base+32'd1});
        @(negedge c0); rx_data=base; rx_valid=1;
        @(negedge c0); rx_data=base+1;
        @(negedge c0); rx_valid=0;
        for(n=0;n<8;n=n+1) begin
            // DW 0 is a mux status DW with non-TLP slots (passed unchanged).
            user_data[255-n*32 -:32]=(n==0) ? STATUS : base+n;
            tx_expected.push_back((n==0) ? STATUS : base+n);
        end
        @(negedge clk);
        while(!bus.com_din_ready) @(negedge clk);
        user_write=1;
        @(negedge clk); user_write=0;
        wait(rx_expected.size()==0 && tx_expected.size()==0);
        repeat(20) @(negedge clk);
    endtask
    task automatic recovered;
        wait(!dut.com_arst && !dut.rst_com && !dut.rst_comrx_fifo &&
             !dut.rst_comtx_fifo && bus.com_din_ready && dut.g_ft601_phy.rx_ready);
        #1;
        if(rx_edges<1 || tx_edges<1)
            $fatal(1,"COM_SEQ_NO_REAPPLY rx=%0d tx=%0d",rx_edges,tx_edges);
        epochs=epochs+1;
        healthy();
        $display("COM_SEQ_RECOVERED epoch=%0d rx=%0d tx=%0d",epochs,rx_edges,tx_edges);
    endtask
    task automatic pulse;
        @(negedge clk); rst=1;
        @(negedge clk); rst=0;
    endtask
    // Case 3 stops clk_c mid-phase (frozen COM synchronizers, possibly a
    // high ack_com) instead of pulsing rst; other cases pulse rst.
    task automatic interrupt;
        if (scenario==3) begin
            @(negedge eclk); e_run=0;
            $display("COM_SEQ_CLOCK_STOP target=%0d state=%0d ack_com=%b",
                target,dut.g_fifo_replay.i_reset.state,dut.g_fifo_replay.i_reset.ack_com);
            wait(dut.com_arst);
            repeat(30) @(negedge clk);
            e_run=1;
        end else pulse();
    endtask
    initial begin
        if ($value$plusargs("CASE=%d",scenario)) begin end
        #300; rst=0;
        #300; e_run=1;
        recovered();
        case(scenario)
            0: pulse();
            1: begin pulse(); @(negedge clk); pulse(); end
            3: pulse();
            2: begin
                @(negedge clk); fault=1;
                repeat(8) @(negedge clk); fault=0;
                wait(!dut.com_arst);
                @(negedge dut.rst_comrx_fifo); fault=1;
                repeat(8) @(negedge clk); fault=0;
            end
            default: $fatal(1,"COM_SEQ_BAD_CASE");
        endcase
        recovered();
        @(negedge eclk); e_run=0;
        wait(dut.com_arst);
        repeat(30) @(negedge clk);
        if(bus.com_din_ready) $fatal(1,"COM_SEQ_EARLY_READY");
        e_run=1;
        recovered();
        // Interrupt every active request/acknowledgement phase. Targeting
        // implementation states chooses stimulus only; acceptance uses the
        // independently observed reset pins, enables and ordered data.
        for(target=1;target<=9;target=target+1) begin
            if(target==7) continue;
            pulse();
            wait(!dut.com_arst);
            if(target==1 || target==2) begin
                wait(dut.g_fifo_replay.i_reset.state==5);
                pulse();
                wait(!dut.com_arst);
            end
            wait(dut.g_fifo_replay.i_reset.state==target);
            interrupt();
            recovered();
        end
        if(rx_seen!=epochs || tx_seen!=epochs*8)
            $fatal(1,"COM_SEQ_DATA_COUNTS");
        $display("COM_SEQ_PASS case=%0d epochs=%0d rx=%0d tx=%0d",scenario,epochs,rx_seen,tx_seen);
        $finish;
    end
    initial begin #400000; $fatal(1,"COM_SEQ_TIMEOUT"); end
endmodule
