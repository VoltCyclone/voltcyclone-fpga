// pcileech_ft601_phy against the FT601 model with ideal c0/c180 clocks
// (0.5 ns / 5.5 ns after the device edge) and zero board delay.
// Scenarios (+SCEN=n):
//   0 basic: one RX burst, then TX
//   1 mixed: random RX bursts and continuous TX with TXE_N full periods
//   2 single words: isolated one-word RX and TX transfers
//   3 reset: arst mid-traffic with clocks stopped; pads release at once,
//     then traffic resumes after reset and is checked exactly
// Pass prints FT601_TB_PASS; any failure prints FT601_TB_FAIL.
`timescale 1ns / 1ps

module tb_ft601_phy;
`ifndef TCO_MIN_NS
`define TCO_MIN_NS 3.5
`endif
`ifndef TCO_MAX_NS
`define TCO_MAX_NS 7.0
`endif
`ifndef T_HIZ_NS
`define T_HIZ_NS 6.0
`endif
    parameter real    TCO_MIN = `TCO_MIN_NS;
    parameter real    TCO_MAX = `TCO_MAX_NS;
    parameter real    T_HIZ   = `T_HIZ_NS;
    parameter integer TX_CAP  = 24;
    parameter integer TX_HOLD = 6;
    parameter integer GUARD   = 3;

    integer scen = 0;
    integer errors = 0;

    // Clocks.
    reg run = 1'b1;
    reg e = 1'b0, c0 = 1'b0, c180 = 1'b0;
    always begin #5.0; if ( run ) e = ~e; end
    always @ ( e ) begin c0 <= #0.5 e; c180 <= #5.5 e; end

    // Resets: arst models phy_not_ready; rst models rst_com (synchronized).
    reg  arst = 1'b1;
    wire rst;
    xpm_cdc_async_rst #( .DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1) ) i_rst (
        .src_arst ( arst ), .dest_clk ( c0 ), .dest_arst ( rst ) );
    reg  model_rst = 1'b1;

    // Pads.
    wire [31:0] data;
    wire [3:0]  be;
    wire        rxf_n, txe_n, oe_n, rd_n, wr_n, siwu_n;
    pullup pu_rxf ( rxf_n );

    // FIFO side.
    wire [31:0] dout;
    wire        dout_valid;
    reg  [31:0] din = 32'h0;
    reg         din_wr_en = 1'b0;
    wire        din_req_data;
    wire        tx_order_err;

    pcileech_ft601_phy #( .GUARD_CYCLES ( GUARD ) ) dut (
        .c0 ( c0 ), .c180 ( c180 ), .rst ( rst ), .arst ( arst ),
        .FT601_BE ( be ), .FT601_DATA ( data ), .FT601_RXF_N ( rxf_n ),
        .FT601_TXE_N ( txe_n ), .FT601_OE_N ( oe_n ), .FT601_RD_N ( rd_n ),
        .FT601_WR_N ( wr_n ), .FT601_SIWU_N ( siwu_n ),
        .dout ( dout ), .dout_valid ( dout_valid ), .din ( din ),
        .din_wr_en ( din_wr_en ), .din_req_data ( din_req_data ),
        .tx_order_err ( tx_order_err ) );

    wire [35:0] fpga_bus;
    genvar gi;
    generate
        for ( gi = 0; gi < 32; gi = gi + 1 ) begin : g_mon
            assign fpga_bus[gi] = dut.g_data[gi].q_t ? 1'bz : dut.g_data[gi].q_o;
        end
        for ( gi = 0; gi < 4; gi = gi + 1 ) begin : g_mon_be
            assign fpga_bus[32+gi] = dut.g_be[gi].q_t ? 1'bz : 1'b1;
        end
    endgenerate

    ft601_model #( .TCO_MIN ( TCO_MIN ), .TCO_MAX ( TCO_MAX ), .T_HIZ ( T_HIZ ),
                   .TX_CAP ( TX_CAP ), .TX_HOLD ( TX_HOLD ) ) m (
        .clk ( e ), .data ( data ), .be ( be ), .rxf_n ( rxf_n ), .txe_n ( txe_n ),
        .oe_n ( oe_n ), .rd_n ( rd_n ), .wr_n ( wr_n ), .model_rst ( model_rst ),
        .fpga_bus ( fpga_bus ) );

    function [31:0] bswap ( input [31:0] w );
        bswap = {w[7:0], w[15:8], w[23:16], w[31:24]};
    endfunction

    // Bus contention: both sides driving DATA at once.
    wire fpga_drives = !dut.g_data[0].q_t;
    always @ ( fpga_drives or m.drive )
        if ( fpga_drives && m.drive ) begin
            #0.001;
            if ( fpga_drives && m.drive ) begin
                errors = errors + 1;
                $display("FT601_TB_ERR contention at %0t", $realtime);
            end
        end

    // TX source: models the standard-mode com TX FIFO (valid one cycle after
    // rd_en). Words are 32'hA000_0000 + n.
    integer tx_avail = 0, tx_sent = 0;
    always @ ( posedge c0 ) begin
        din_wr_en <= 1'b0;
        if ( din_req_data && (tx_avail > tx_sent) && !rst ) begin
            din_wr_en <= 1'b1;
            din       <= 32'hA000_0000 + tx_sent;
            tx_sent    = tx_sent + 1;
        end
    end

    // RX sink: words pushed into the model are 32'hB000_0000 + n on the bus.
    integer rx_pushed = 0, rx_got = 0, rx_base = 0;
    always @ ( posedge c0 )
        if ( dout_valid ) begin
            if ( dout !== bswap(32'hB000_0000 + rx_base + rx_got) ) begin
                errors = errors + 1;
                $display("FT601_TB_ERR rx word %0d got %h want %h at %0t",
                         rx_got, dout, bswap(32'hB000_0000 + rx_base + rx_got), $realtime);
            end
            rx_got = rx_got + 1;
        end

    always @ ( posedge c0 )
        if ( tx_order_err ) begin
            errors = errors + 1;
            $display("FT601_TB_ERR tx_order_err at %0t", $realtime);
        end

    // Queue invariant: ap <= ip <= wp (mod 32), at most 16 entries.
    reg inv_reported = 1'b0;
    always @ ( posedge c0 )
        if ( !rst && !inv_reported && ( ((dut.ip - dut.ap) & 31) > ((dut.wp - dut.ap) & 31) || ((dut.wp - dut.ap) & 31) > 16 ) ) begin
            inv_reported = 1'b1;
            errors = errors + 1;
            $display("FT601_TB_ERR queue invariant wp=%0d ip=%0d ap=%0d state=%0d at %0t", dut.wp, dut.ip, dut.ap, dut.state, $realtime);
        end

    integer n_refuse = 0, n_rx_entries = 0;
    always @ ( posedge c0 ) begin
        if ( !rst && dut.tx_refuse ) n_refuse = n_refuse + 1;
        if ( !rst && dut.state == 1 && !dut.in_rxf_n ) n_rx_entries = n_rx_entries + 1;
    end

    task push_rx ( input integer n );
        integer j;
        begin
            for ( j = 0; j < n; j = j + 1 ) begin
                m.push_rx(32'hB000_0000 + rx_base + rx_pushed);
                rx_pushed = rx_pushed + 1;
            end
        end
    endtask

    // Check the model's TX log: every non-filler word in order, exactly once.
    integer tx_base = 0, tx_log_base = 0;
    task check_tx;
        integer j, n;
        reg [31:0] w;
        begin
            n = 0;
            for ( j = tx_log_base; j < m.tx_n; j = j + 1 ) begin
                w = bswap(m.tx_log[j]);
                if ( w != 32'h66665555 ) begin
                    if ( w !== 32'hA000_0000 + tx_base + n ) begin
                        errors = errors + 1;
                        $display("FT601_TB_ERR tx word %0d got %h want %h", n, w, 32'hA000_0000 + tx_base + n);
                    end
                    n = n + 1;
                end
            end
            if ( n != tx_sent - tx_base ) begin
                errors = errors + 1;
                $display("FT601_TB_ERR tx delivered %0d of %0d", n, tx_sent - tx_base);
            end
            $display("FT601_TB_INFO tx delivered %0d words", n);
        end
    endtask

    task check_rx;
        begin
            if ( rx_got != rx_pushed ) begin
                errors = errors + 1;
                $display("FT601_TB_ERR rx delivered %0d of %0d", rx_got, rx_pushed);
            end
            if ( m.rx_xfers != rx_pushed ) begin
                errors = errors + 1;
                $display("FT601_TB_ERR model transferred %0d of %0d", m.rx_xfers, rx_pushed);
            end
            $display("FT601_TB_INFO rx delivered %0d words", rx_got);
        end
    endtask

    // Stop the TX source, then wait for the queue to drain and every RX
    // word to arrive (bounded).
    task quiesce;
        integer w;
        begin
            tx_avail = tx_sent;
            w = 0;
            while ( w < 20000 && !( dut.wp == dut.ap && rx_got == rx_pushed && dut.state == 1 ) ) begin
                @( posedge e );
                w = w + 1;
            end
            repeat ( 100 ) @( posedge e );
        end
    endtask

    task release_reset;
        begin
            repeat ( 3 ) @( posedge e );
            model_rst = 1'b0;
            repeat ( 2 ) @( posedge e );
            arst = 1'b0;
            repeat ( 20 ) @( posedge e );
        end
    endtask

    integer it, n;
    initial begin
        if ( !$value$plusargs("SCEN=%d", scen) ) scen = 0;
        if ( $value$plusargs("SEED=%d", n) ) n = $urandom(n);
        release_reset();
        case ( scen )
            0: begin
                push_rx(100); m.open_rx(100);
                repeat ( 300 ) @( posedge e );
                tx_avail = 200;
                repeat ( 300 ) @( posedge e );
                quiesce();
            end
            1: begin
                for ( it = 0; it < 60; it = it + 1 ) begin
                    n = 1 + ($urandom % 40);
                    push_rx(n); m.open_rx(n);
                    tx_avail = tx_avail + ($urandom % 60);
                    repeat ( $urandom % 80 ) @( posedge e );
                end
                quiesce();
            end
            2: begin
                for ( it = 0; it < 20; it = it + 1 ) begin
                    push_rx(1); m.open_rx(1);
                    repeat ( 40 ) @( posedge e );
                    tx_avail = tx_avail + 1;
                    repeat ( 40 ) @( posedge e );
                end
                quiesce();
            end
            3: begin
                push_rx(300); m.open_rx(300);
                tx_avail = 300;
                repeat ( 37 ) @( posedge e );
                #2.3;
                model_rst = 1'b1;       // FT601 held in reset
                run  = 1'b0;            // its clock stops
                #1.0;
                arst = 1'b1;
                #0.1;
                if ( oe_n !== 1'b1 || rd_n !== 1'b1 || wr_n !== 1'b1 || !dut.g_data[0].q_t || !dut.g_be[3].q_t ) begin
                    errors = errors + 1;
                    $display("FT601_TB_ERR pads not released asynchronously");
                end
                else
                    $display("FT601_TB_INFO pads released with clocks stopped");
                #200;
                // Restart: FT601 reset discards its FIFOs; start fresh counts.
                model_rst = 1'b1;
                run = 1'b1;
                repeat ( 10 ) @( posedge e );
                rx_base   = rx_base + rx_pushed + 1000;
                rx_pushed = 0; rx_got = 0;
                m.rx_xfers = 0;
                tx_log_base = m.tx_n;
                tx_base   = tx_sent;
                tx_avail  = tx_sent;
                release_reset();
                tx_log_base = m.tx_n;   // drop fillers emitted across reset
                push_rx(120); m.open_rx(120);
                tx_avail = tx_avail + 150;
                repeat ( 600 ) @( posedge e );
                quiesce();
            end
        endcase
        $display("FT601_TB_INFO end wp=%0d ip=%0d ap=%0d state=%0d txe_n=%b din_req=%b src avail=%0d sent=%0d", dut.wp, dut.ip, dut.ap, dut.state, txe_n, din_req_data, tx_avail, tx_sent);
        $display("FT601_TB_INFO refusals=%0d rx_entries=%0d", n_refuse, n_rx_entries);
        check_rx();
        check_tx();
        errors = errors + m.err;
        if ( errors == 0 ) $display("FT601_TB_PASS scen=%0d", scen);
        else               $display("FT601_TB_FAIL scen=%0d errors=%0d", scen, errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FT601_TB_FAIL timeout");
        $finish;
    end
endmodule
