// FT601 245 synchronous FIFO slave model (datasheet v1.06, Figures 4.6-4.8,
// Table 4.2). E is a rising edge of clk.
//   - Outputs (RXF_N, TXE_N, DATA, BE) change TCO after E, TCO random in
//     [TCO_MIN, TCO_MAX] = [3.5, 7.0] ns (T2 hold, 10 - T1 setup).
//   - DATA/BE are driven TCO after an edge that samples OE_N low, and released
//     T_HIZ after an edge that samples OE_N high.
//   - Read: a word is transferred at E iff RXF_N and RD_N are low at E (OE_N
//     must also be low). The head word is driven on OE_N alone.
//   - Write: a word is accepted at E iff WR_N and TXE_N are low at E.
//   - FPGA inputs must meet T3 setup (1.0 ns) and T4 hold (4.8 ns) at E.
// Errors are counted in err; every check prints FT601_MODEL_ERR.
`timescale 1ns / 1ps

module ft601_model #(
    parameter real    TCO_MIN  = 3.5,
    parameter real    TCO_MAX  = 7.0,
    parameter real    T_HIZ    = 6.0,
    parameter real    T_SU     = 1.0,
    parameter real    T_H      = 4.8,
    parameter integer TX_CAP   = 64,    // words before TXE_N rises
    parameter integer TX_HOLD  = 8      // edges TXE_N stays high when full
) (
    input               clk,
    inout [31:0]        data,
    inout [3:0]         be,
    output reg          rxf_n = 1'b1,
    output reg          txe_n = 1'b1,
    input               oe_n,
    input               rd_n,
    input               wr_n,
    input               model_rst,     // FT601 RESET_N low: idle, bus released
    input [35:0]        fpga_bus       // FPGA-driven DATA/BE (z when released)
);
    // RX source (host to FPGA).
    reg [31:0] rx_q [0:65535];
    integer    rx_wr = 0, rx_rd = 0;
    integer    rx_gate = 0;             // words the host has made available
    // TX sink (FPGA to host).
    reg [31:0] tx_log [0:65535];
    integer    tx_n = 0;
    integer    tx_fill = 0, tx_hold = 0;
    reg        tx_block = 1'b0;         // forced TXE_N high (test control)
    integer    err = 0;
    integer    rx_xfers = 0;

    reg        drive = 1'b0;
    integer    oe_gen = 0;
    integer    rel_tok = -1;
    reg [31:0] dq = 32'h0;
    assign data = drive ? dq : 32'hzzzzzzzz;
    assign be   = drive ? 4'hf : 4'hz;

    // Setup/hold check on FPGA-driven inputs.
    realtime last_e = -100.0, last_chg = -100.0;
    wire [38:0] fpga_in = {oe_n, rd_n, wr_n, fpga_bus};
    always @ ( fpga_in ) begin
        last_chg = $realtime;
        if ( ($realtime - last_e) < T_H && last_e > 0 && !model_rst ) begin
            err = err + 1;
            $display("FT601_MODEL_ERR hold %0.3f ns after edge at %0t", $realtime - last_e, $realtime);
        end
    end

    function real tco;
        input integer dummy;
        tco = TCO_MIN + (TCO_MAX - TCO_MIN) * ($urandom % 1001) / 1000.0;
    endfunction

    integer    k;
    reg        s_oe, s_rd, s_wr, s_rxf, s_txe;
    reg [31:0] s_data;
    reg [3:0]  s_be;
    real       d;
    always @ ( posedge clk ) begin
        last_e = $realtime;
        if ( ($realtime - last_chg) < T_SU && !model_rst ) begin
            err = err + 1;
            $display("FT601_MODEL_ERR setup %0.3f ns before edge at %0t", $realtime - last_chg, $realtime);
        end
        s_oe = oe_n; s_rd = rd_n; s_wr = wr_n; s_rxf = rxf_n; s_txe = txe_n;
        s_data = data; s_be = be;
        if ( model_rst ) begin
            rx_rd   = rx_wr;
            rx_gate = rx_wr;
            tx_fill = 0;
            tx_hold = 0;
        end
        else begin
            // Read transfer.
            if ( !s_rxf && !s_rd ) begin
                if ( s_oe ) begin
                    err = err + 1;
                    $display("FT601_MODEL_ERR RD_N low without OE_N at %0t", $realtime);
                end
                rx_rd    = rx_rd + 1;
                rx_xfers = rx_xfers + 1;
            end
            // Write acceptance.
            if ( !s_txe && !s_wr ) begin
                if ( s_be !== 4'hf || ^s_data === 1'bx ) begin
                    err = err + 1;
                    $display("FT601_MODEL_ERR write with BE=%h DATA=%h at %0t", s_be, s_data, $realtime);
                end
                tx_log[tx_n] = s_data;
                tx_n         = tx_n + 1;
                tx_fill      = tx_fill + 1;
            end
            if ( tx_fill >= TX_CAP && tx_hold == 0 )
                tx_hold = TX_HOLD;
            else if ( tx_hold > 0 ) begin
                tx_hold = tx_hold - 1;
                if ( tx_hold == 0 ) tx_fill = 0;
            end
        end
        d = tco(0);
        rxf_n <= #(d) model_rst || (rx_rd >= rx_gate);
        txe_n <= #(d) model_rst || tx_block || (tx_hold != 0) || (tx_fill >= TX_CAP);
        if ( !s_oe && !model_rst ) begin
            oe_gen = oe_gen + 1;            // cancels any pending release
            dq    <= #(d) rx_q[rx_rd[15:0]];
            drive <= #(d) 1'b1;
        end
        else
            rel_tok <= #(T_HIZ) oe_gen;
    end

    // Release T_HIZ after an edge that sampled OE_N high, unless an edge in
    // between sampled OE_N low again (which changes oe_gen).
    always @ ( rel_tok )
        if ( rel_tok == oe_gen ) drive = 1'b0;

    task push_rx ( input [31:0] w );
        begin rx_q[rx_wr[15:0]] = w; rx_wr = rx_wr + 1; end
    endtask
    task open_rx ( input integer n );   // make n more queued words available
        begin rx_gate = (rx_gate + n > rx_wr) ? rx_wr : rx_gate + n; end
    endtask
endmodule
