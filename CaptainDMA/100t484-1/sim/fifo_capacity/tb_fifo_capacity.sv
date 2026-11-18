`timescale 1ns / 1ps
`include "pcileech_header.svh"

// Whole-packet capacity bench (R3) for pcileech_tlps128_src_fifo (host TX)
// and pcileech_tlps128_dst_fifo (PCIe RX), with the exported FIFO Generator
// functional models (prog_full thresholds 763 / 13 / 1787).
//
// Both sources are unstallable, as in production: the host TX DW stream and
// the PCIe RX beat stream. Both readers stall for long stretches, so the FIFOs
// fill and admission is refused. Every DW carries {packet id, index}.
//
// Checked (marker prefix CAP_):
//   TX_/RX_CUT       a packet starts while another is open at the output
//   TX_/RX_ORPHAN    a DW outside any packet
//   TX_/RX_ORDER     a packet other than the next admitted one, or a wrong
//                    id/index inside a packet
//   TX_/RX_LEN       packet length differs from min(sent, cap): TX caps at
//                    1029 DW, RX at 258 beats (1032 DW for a full last beat)
//   TX_OVERFLOW      a data beat or token written while that FIFO is full
//   RX_OVERFLOW      an RX beat written while the FIFO is full
//   TX_/RX_LOST      an admitted packet missing after the final drain
//   LAG              a FIFO's occupancy, at a write edge with prog_full low,
//                    exceeds threshold - 1 + 2: the reservation budgets at
//                    most 2 writes the flag has not shown yet. Occupancy is
//                    counted from the model pins (wr_en && !full, rd_en &&
//                    !empty); the maximum excess and the minimum free space
//                    are reported per FIFO.
//   COVERAGE         no refusals, no prog_full, no capped packet (CASE 0/2),
//                    or no token prog_full (CASE 1 with clk_pcie below
//                    100 MHz: tokens cross into pkt_count every clk_pcie
//                    cycle, so only back-to-back 1-DW packets faster than
//                    clk_pcie can fill the token FIFO)
//
// Plusargs: +CASE=0|1|2 (mixed / tiny packets / maximum and oversize),
// +PCIE_NS=<clk_pcie period>, +SEED=<n>, +PKTS=<packets per direction>.
module tb_fifo_capacity;

    // ------------------------------------------------------------------
    // Clocks and resets
    // ------------------------------------------------------------------
    real pcie_half = 8.0;
    reg  clk_sys = 0, clk_pcie = 0;
    always #5.0 clk_sys = ~clk_sys;
    always #(pcie_half) clk_pcie = ~clk_pcie;

    reg  rst_fifo = 1, rst_sys = 1, rst_pcie = 1;

    integer CASE = 0, SEED = 1, PKTS = 1500;
    integer errors = 0;

    // ------------------------------------------------------------------
    // DUTs
    // ------------------------------------------------------------------
    reg  [31:0] tx_data = 0;
    reg         tx_last = 0, tx_valid = 0;
    reg         tx_rdy  = 0;
    IfAXIS128   tx_out();
    assign tx_out.tready = tx_rdy;

    pcileech_tlps128_src_fifo dut_tx (
        .rst            ( rst_pcie      ),
        .rst_sys        ( rst_sys       ),
        .rst_fifo       ( rst_fifo      ),
        .clk_pcie       ( clk_pcie      ),
        .clk_sys        ( clk_sys       ),
        .dfifo_tx_data  ( tx_data       ),
        .dfifo_tx_last  ( tx_last       ),
        .dfifo_tx_valid ( tx_valid      ),
        .tlps_out       ( tx_out.source )
    );

    reg  [127:0] rx_tdata = 0;
    reg  [3:0]   rx_tkeepdw = 0;
    reg          rx_tvalid = 0, rx_tlast = 0, rx_first = 0;
    reg          rx_rdy = 0;
    IfAXIS128    rx_in();
    IfPCIeFifoTlp dfifo();
    assign rx_in.tdata   = rx_tdata;
    assign rx_in.tkeepdw = rx_tkeepdw;
    assign rx_in.tvalid  = rx_tvalid;
    assign rx_in.tlast   = rx_tlast;
    assign rx_in.tuser   = {8'd0, rx_first};
    assign dfifo.rx_rd_en = rx_rdy;
    assign dfifo.tx_data  = 32'h0;
    assign dfifo.tx_last  = 1'b0;
    assign dfifo.tx_valid = 1'b0;

    pcileech_tlps128_dst_fifo dut_rx (
        .rst        ( rst_sys           ),
        .rst_fifo   ( rst_fifo          ),
        .clk_pcie   ( clk_pcie          ),
        .clk_sys    ( clk_sys           ),
        .tlps_in    ( rx_in.sink_lite   ),
        .dfifo      ( dfifo.mp_pcie     )
    );

    // ------------------------------------------------------------------
    // Flag lag: true occupancy vs prog_full, per FIFO (model pins).
    // Counters are nonblocking, so a check at an edge sees pre-edge values
    // even when both clocks edge together.
    // ------------------------------------------------------------------
    `define CAP_OCC(TAG, INST, WCLK, RCLK, THR, DEPTH)                              \
    integer TAG``_wr = 0, TAG``_rd = 0, TAG``_lag = -99999, TAG``_minfree = DEPTH;  \
    always @ ( posedge WCLK ) begin                                                 \
        if ( INST.wr_en && !INST.full ) TAG``_wr <= TAG``_wr + 1;                   \
        if ( !INST.rst && !INST.prog_full ) begin                                   \
            if ( TAG``_wr - TAG``_rd - (THR - 1) > TAG``_lag )                      \
                TAG``_lag = TAG``_wr - TAG``_rd - (THR - 1);                        \
            if ( TAG``_wr - TAG``_rd - (THR - 1) > 2 ) begin                        \
                errors = errors + 1;                                                \
                $display("CAP_LAG %s occupancy %0d with prog_full low (threshold %0d)", \
                         `"TAG`", TAG``_wr - TAG``_rd, THR);                        \
            end                                                                     \
        end                                                                         \
        if ( DEPTH - (TAG``_wr - TAG``_rd) < TAG``_minfree )                        \
            TAG``_minfree = DEPTH - (TAG``_wr - TAG``_rd);                          \
    end                                                                             \
    always @ ( posedge RCLK )                                                       \
        if ( INST.rd_en && !INST.empty ) TAG``_rd <= TAG``_rd + 1;                  \
    always @ ( posedge INST.rst ) begin TAG``_wr <= 0; TAG``_rd <= 0; end

    `CAP_OCC(txd, dut_tx.i_fifo_134_134_clk2_rxfifo, clk_sys, clk_pcie, 763, 1023)
    `CAP_OCC(tok, dut_tx.i_fifo_1_1_clk2, clk_sys, clk_pcie, 13, 15)
    `CAP_OCC(rxd, dut_rx.i_fifo_134_134_clk2, clk_pcie, clk_sys, 1787, 2047)

    // ------------------------------------------------------------------
    // Packet bookkeeping
    // ------------------------------------------------------------------
    localparam integer MAXP = 65536;
    integer tx_len [0:MAXP-1];
    integer rx_len [0:MAXP-1];
    integer tx_adm [0:MAXP-1];      // admitted ids, in order
    integer rx_adm [0:MAXP-1];
    integer tx_nadm = 0, rx_nadm = 0, tx_nref = 0, rx_nref = 0;
    integer tx_rd = 0, rx_rd = 0;   // next admitted index expected at the output
    integer tx_capped = 0, rx_capped = 0;
    integer tx_pfull_cycles = 0, rx_pfull_cycles = 0, tok_pfull_cycles = 0;
    integer tx_sent = 0, rx_sent = 0;
    reg     src_done_tx = 0, src_done_rx = 0;

    function integer tx_expect(input integer len);
        tx_expect = (len > 1029) ? 1029 : len;
    endfunction
    function integer rx_expect(input integer len);
        rx_expect = (len > 1032) ? 1032 : len;
    endfunction

    function integer pick_len(input integer c);
        integer r;
        begin
            r = $urandom % 100;
            if ( c == 1 )
                pick_len = (r < 85) ? 1 : 2;
            else if ( c == 2 )
                pick_len = (r < 60) ? 1029 : (r < 80) ? (1020 + $urandom % 9) : (1030 + $urandom % 1200);
            else
                pick_len = (r < 55) ? (1 + $urandom % 8) : (r < 80) ? (9 + $urandom % 300)
                         : (r < 95) ? (1000 + $urandom % 30) : (1030 + $urandom % 600);
        end
    endfunction

    // ------------------------------------------------------------------
    // TX source (clk_sys, unstallable host DW stream)
    // ------------------------------------------------------------------
    task automatic send_tx(input integer id, input integer len);
        integer i;
        begin
            tx_len[id] = len;
            for ( i = 0; i < len; i = i + 1 ) begin
                if ( CASE != 1 && ($urandom % 32) == 0 ) begin
                    tx_valid <= 1'b0;
                    @( posedge clk_sys );
                end
                tx_valid <= 1'b1;
                tx_data  <= {id[15:0], i[15:0]};
                tx_last  <= (i == len - 1);
                @( posedge clk_sys );
            end
            tx_valid <= 1'b0;
            tx_last  <= 1'b0;
        end
    endtask

    // TX admission monitor: a packet's first DW is seen with host_mid low.
    always @ ( posedge clk_sys )
        if ( tx_valid && !dut_tx.host_mid ) begin
            if ( dut_tx.tx_pass ) begin
                tx_adm[tx_nadm] = tx_data[31:16];
                tx_nadm = tx_nadm + 1;
                if ( tx_len[tx_data[31:16]] > 1029 )
                    tx_capped = tx_capped + 1;
            end
            else
                tx_nref = tx_nref + 1;
        end

    always @ ( posedge clk_sys ) begin
        if ( dut_tx.tvalid && dut_tx.acc_sys && dut_tx.full_data ) begin
            errors = errors + 1;
            $display("CAP_TX_OVERFLOW data beat written while full at %0t", $realtime);
        end
        if ( dut_tx.tvalid && dut_tx.tlast && dut_tx.acc_sys && dut_tx.full_tok ) begin
            errors = errors + 1;
            $display("CAP_TX_OVERFLOW token written while full at %0t", $realtime);
        end
        if ( dut_tx.acc_sys && dut_tx.pfull_data ) tx_pfull_cycles = tx_pfull_cycles + 1;
        if ( dut_tx.acc_sys && dut_tx.pfull_tok )  tok_pfull_cycles = tok_pfull_cycles + 1;
    end

    // TX sink (clk_pcie): one beat per cycle with tvalid.
    reg     tx_open = 0;
    integer tx_cur = 0, tx_idx = 0;
    integer d;
    reg [31:0] dw;
    always @ ( posedge clk_pcie )
        if ( tx_out.tvalid ) begin
            for ( d = 0; d < 4; d = d + 1 )
                if ( tx_out.tkeepdw[d] ) begin
                    dw = tx_out.tdata[32*d +: 32];
                    if ( d == 0 && tx_out.tuser[0] ) begin
                        if ( tx_open ) begin
                            errors = errors + 1;
                            $display("CAP_TX_CUT packet %0d open at %0d DW when %0d starts", tx_cur, tx_idx, dw[31:16]);
                        end
                        tx_open = 1;
                        tx_cur  = dw[31:16];
                        tx_idx  = 0;
                        if ( tx_rd >= tx_nadm || tx_adm[tx_rd] != tx_cur ) begin
                            errors = errors + 1;
                            $display("CAP_TX_ORDER packet %0d, expected admitted %0d", tx_cur,
                                     (tx_rd < tx_nadm) ? tx_adm[tx_rd] : -1);
                        end
                    end
                    if ( !tx_open ) begin
                        errors = errors + 1;
                        $display("CAP_TX_ORPHAN dw %08h", dw);
                    end
                    else if ( dw[31:16] != tx_cur[15:0] || dw[15:0] != tx_idx[15:0] ) begin
                        errors = errors + 1;
                        $display("CAP_TX_ORDER dw %08h in packet %0d at index %0d", dw, tx_cur, tx_idx);
                    end
                    tx_idx = tx_idx + 1;
                end
            if ( tx_out.tlast && tx_open ) begin
                if ( tx_idx != tx_expect(tx_len[tx_cur]) ) begin
                    errors = errors + 1;
                    $display("CAP_TX_LEN packet %0d: %0d DW, sent %0d, expected %0d",
                             tx_cur, tx_idx, tx_len[tx_cur], tx_expect(tx_len[tx_cur]));
                end
                tx_open = 0;
                tx_rd   = tx_rd + 1;
            end
        end

    // ------------------------------------------------------------------
    // RX source (clk_pcie, unstallable PCIe RX beats)
    // ------------------------------------------------------------------
    task automatic send_rx(input integer id, input integer len);
        integer i, k, n;
        begin
            rx_len[id] = len;
            for ( i = 0; i < len; i = i + 4 ) begin
                if ( ($urandom % 32) == 0 ) begin
                    rx_tvalid <= 1'b0;
                    @( posedge clk_pcie );
                end
                n = (len - i >= 4) ? 4 : (len - i);
                for ( k = 0; k < 4; k = k + 1 )
                    rx_tdata[32*k +: 32] <= (k < n) ? {id[15:0], 16'(i + k)} : 32'h0;
                rx_tkeepdw <= (n == 4) ? 4'b1111 : (n == 3) ? 4'b0111 : (n == 2) ? 4'b0011 : 4'b0001;
                rx_tvalid  <= 1'b1;
                rx_first   <= (i == 0);
                rx_tlast   <= (i + 4 >= len);
                @( posedge clk_pcie );
            end
            rx_tvalid <= 1'b0;
            rx_tlast  <= 1'b0;
            rx_first  <= 1'b0;
        end
    endtask

    always @ ( posedge clk_pcie )
        if ( rx_tvalid && rx_first ) begin
            if ( dut_rx.rx_pass ) begin
                rx_adm[rx_nadm] = rx_tdata[31:16];
                rx_nadm = rx_nadm + 1;
                if ( rx_len[rx_tdata[31:16]] > 1032 )
                    rx_capped = rx_capped + 1;
            end
            else
                rx_nref = rx_nref + 1;
        end

    always @ ( posedge clk_pcie ) begin
        if ( rx_tvalid && dut_rx.rx_pass && dut_rx.fifo_full ) begin
            errors = errors + 1;
            $display("CAP_RX_OVERFLOW beat written while full at %0t", $realtime);
        end
        if ( dut_rx.acc_pcie && dut_rx.fifo_pfull ) rx_pfull_cycles = rx_pfull_cycles + 1;
    end

    // RX sink (clk_sys): per-DW outputs of dst_fifo.
    reg     rx_open = 0;
    integer rx_cur = 0, rx_idx = 0;
    integer e;
    reg [31:0] rw;
    always @ ( posedge clk_sys )
        for ( e = 0; e < 4; e = e + 1 )
            if ( dfifo.rx_valid[e] ) begin
                rw = dfifo.rx_data[e];
                if ( e == 0 && dfifo.rx_first[0] ) begin
                    if ( rx_open ) begin
                        errors = errors + 1;
                        $display("CAP_RX_CUT packet %0d open at %0d DW when %0d starts", rx_cur, rx_idx, rw[31:16]);
                    end
                    rx_open = 1;
                    rx_cur  = rw[31:16];
                    rx_idx  = 0;
                    if ( rx_rd >= rx_nadm || rx_adm[rx_rd] != rx_cur ) begin
                        errors = errors + 1;
                        $display("CAP_RX_ORDER packet %0d, expected admitted %0d", rx_cur,
                                 (rx_rd < rx_nadm) ? rx_adm[rx_rd] : -1);
                    end
                end
                if ( !rx_open ) begin
                    errors = errors + 1;
                    $display("CAP_RX_ORPHAN dw %08h", rw);
                end
                else begin
                    // A capped packet's forced last beat is full: its DWs
                    // beyond the 1029 legal ones are still the source's.
                    if ( rw[31:16] != rx_cur[15:0] || rw[15:0] != rx_idx[15:0] ) begin
                        errors = errors + 1;
                        $display("CAP_RX_ORDER dw %08h in packet %0d at index %0d", rw, rx_cur, rx_idx);
                    end
                    rx_idx = rx_idx + 1;
                    if ( dfifo.rx_last[e] ) begin
                        if ( rx_idx != rx_expect(rx_len[rx_cur]) ) begin
                            errors = errors + 1;
                            $display("CAP_RX_LEN packet %0d: %0d DW, sent %0d, expected %0d",
                                     rx_cur, rx_idx, rx_len[rx_cur], rx_expect(rx_len[rx_cur]));
                        end
                        rx_open = 0;
                        rx_rd   = rx_rd + 1;
                    end
                end
            end

    // ------------------------------------------------------------------
    // Readers: long stalls so the FIFOs fill; always ready once drain is set.
    // ------------------------------------------------------------------
    reg drain = 0;
    // Each reader starts with a stall, so every run fills both FIFOs early.
    initial begin : tx_reader
        integer n;
        tx_rdy <= 1'b0;
        wait ( !rst_sys );
        repeat ( 4000 ) @( posedge clk_pcie );
        forever begin
            n = 200 + $urandom % 3000;
            repeat ( n ) begin
                @( posedge clk_pcie );
                tx_rdy <= drain || (($urandom % 4) != 0);
            end
            n = 300 + $urandom % ((CASE == 1) ? 4000 : 6000);
            repeat ( n ) begin
                @( posedge clk_pcie );
                tx_rdy <= drain;
            end
        end
    end
    initial begin : rx_reader
        integer n;
        rx_rdy <= 1'b0;
        wait ( !rst_sys );
        repeat ( 4000 ) @( posedge clk_sys );
        forever begin
            n = 200 + $urandom % 3000;
            repeat ( n ) begin
                @( posedge clk_sys );
                rx_rdy <= drain || (($urandom % 4) != 0);
            end
            n = 300 + $urandom % 8000;
            repeat ( n ) begin
                @( posedge clk_sys );
                rx_rdy <= drain;
            end
        end
    end

    // ------------------------------------------------------------------
    // Sequence
    // ------------------------------------------------------------------
    initial begin : src_tx
        integer id;
        wait ( !rst_sys );
        repeat ( 200 ) @( posedge clk_sys );
        for ( id = 0; id < PKTS; id = id + 1 ) begin
            send_tx(id, pick_len(CASE));
            tx_sent = tx_sent + 1;
        end
        src_done_tx = 1;
    end
    initial begin : src_rx
        integer id;
        wait ( !rst_sys );
        repeat ( 200 ) @( posedge clk_pcie );
        for ( id = 0; id < PKTS; id = id + 1 ) begin
            send_rx(id, pick_len(CASE));
            rx_sent = rx_sent + 1;
        end
        src_done_rx = 1;
    end

    initial begin
        integer pns = 16, guard;
        if ( $value$plusargs("CASE=%d", CASE) ) ;
        if ( $value$plusargs("SEED=%d", SEED) ) ;
        if ( $value$plusargs("PKTS=%d", PKTS) ) ;
        if ( $value$plusargs("PCIE_NS=%d", pns) ) pcie_half = pns / 2.0;
        // Randomization is seeded per run with xsim -sv_seed (SEED is reported).
        // FIFO reset pin, then the window reset, as the reset sequencer does.
        repeat ( 60 ) @( posedge clk_sys );
        rst_fifo <= 0;
        repeat ( 20 ) @( posedge clk_pcie );
        rst_pcie <= 0;
        repeat ( 80 ) @( posedge clk_sys );
        rst_sys <= 0;
        wait ( src_done_tx && src_done_rx );
        drain = 1;
        guard = 0;
        while ( guard < 400000 && (tx_rd < tx_nadm || rx_rd < rx_nadm) ) begin
            @( posedge clk_sys );
            guard = guard + 1;
        end
        repeat ( 200 ) @( posedge clk_sys );
        if ( tx_rd != tx_nadm || tx_open ) begin
            errors = errors + 1;
            $display("CAP_TX_LOST delivered %0d of %0d admitted packets", tx_rd, tx_nadm);
        end
        if ( rx_rd != rx_nadm || rx_open ) begin
            errors = errors + 1;
            $display("CAP_RX_LOST delivered %0d of %0d admitted packets", rx_rd, rx_nadm);
        end
        if ( tx_nref == 0 || rx_nref == 0 || tx_pfull_cycles == 0 || rx_pfull_cycles == 0
             || (CASE == 1 && pns > 10 && tok_pfull_cycles == 0)
             || (CASE != 1 && (tx_capped == 0 || rx_capped == 0)) ) begin
            errors = errors + 1;
            $display("CAP_COVERAGE refused tx=%0d rx=%0d pfull cycles tx=%0d tok=%0d rx=%0d capped tx=%0d rx=%0d",
                     tx_nref, rx_nref, tx_pfull_cycles, tok_pfull_cycles, rx_pfull_cycles, tx_capped, rx_capped);
        end
        $display("CAP_INFO case=%0d pcie_ns=%0d seed=%0d tx sent=%0d admitted=%0d refused=%0d capped=%0d | rx sent=%0d admitted=%0d refused=%0d capped=%0d | pfull cycles tx=%0d tok=%0d rx=%0d",
                 CASE, pns, SEED, tx_sent, tx_nadm, tx_nref, tx_capped, rx_sent, rx_nadm, rx_nref, rx_capped,
                 tx_pfull_cycles, tok_pfull_cycles, rx_pfull_cycles);
        $display("CAP_OCC max excess over threshold-1 with prog_full low: tx data=%0d tok=%0d rx=%0d (budget 2) | min free: tx data=%0d tok=%0d rx=%0d",
                 txd_lag, tok_lag, rxd_lag, txd_minfree, tok_minfree, rxd_minfree);
        if ( errors == 0 ) $display("CAP_PASS");
        else               $display("CAP_FAIL errors=%0d", errors);
        $finish;
    end

endmodule
