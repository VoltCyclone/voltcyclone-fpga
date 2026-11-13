//
// PCILeech FPGA.
//
// FT601 245 synchronous FIFO master on the compensated c0/c180 clocks
// (pcileech_ft601_clk). Same FIFO-side interface as pcileech_ft601.
//
// Edge model (FT600Q-FT601Q datasheet v1.06, Figures 4.6-4.8, Table 4.2).
// E_k is an FT601 CLK rise at the device.
//   - Input: the ILOGIC register on c0 edge k holds what the FT601 drove for
//     E_k. Fabric logic sees it at c0 edge k+1.
//   - Output: a c0 register written at edge j is copied into its c180 OLOGIC
//     register with no logic in between; the FT601 samples it at E_{j+1}.
//   - Read: a word is transferred at E only when RXF_N and RD_N are both low
//     at E. The FT601 drives the first word on OE_N alone.
//   - Write: a word is accepted at E only when WR_N and TXE_N are both low at E.
// A strobe written at edge j is therefore judged against the input sample the
// fabric sees at edge j+2. rd_d1/wr_d1 delay the issued strobes to line them
// up with that sample, so RX validity and TX acceptance come from the pins,
// never from FSM state.
//
// Bus ownership. The FPGA drives DATA/BE except while reading. Entering RX
// releases the pads one cycle before OE_N is issued. Leaving RX deasserts
// OE_N/RD_N, then waits GUARD_CYCLES before driving again. The datasheet gives
// no OE_N-to-Hi-Z time; GUARD_CYCLES = 3 leaves at least 25 ns after the
// FT601 samples OE_N high (the legacy controller allows none).
//
// TX replay. Words stay in the queue until accepted. If a word is refused
// (TXE_N high), issue stops, in-flight results drain, and the issue pointer
// rewinds to the oldest unaccepted word. This assumes TXE_N, once high, stays
// high for at least two cycles; tx_order_err records a later word being
// accepted after a refusal.
//
// Reset. arst (phy_not_ready from pcileech_ft601_clk, a clk register) presets
// every output and tristate register asynchronously: pads released, strobes
// inactive, also with c180 stopped. Release is synchronous to c180. rst is
// the c0-domain reset (rst_com) and covers the same condition.
//

`timescale 1ns / 1ps

// Registers carry power-up values (pads released, strobes inactive) as well as
// a reset, so Verilator's PROCASSINIT is waived for this module.
/* verilator lint_off PROCASSINIT */
module pcileech_ft601_phy #(
    parameter integer GUARD_CYCLES = 3
) (
    input               c0,
    input               c180,
    input               rst,            // c0 domain, asserted while arst is
    input               arst,           // asynchronous pad release
    // TO/FROM PADS
    output [3:0]        FT601_BE,
    inout [31:0]        FT601_DATA,
    input               FT601_RXF_N,
    input               FT601_TXE_N,
    output              FT601_OE_N,
    output              FT601_RD_N,
    output              FT601_WR_N,
    output              FT601_SIWU_N,
    // TO/FROM FIFO
    output reg [31:0]   dout = 32'h0,
    output reg          dout_valid = 1'b0,
    input [31:0]        din,
    input               din_wr_en,
    output              din_req_data,
    // STATUS
    output reg          tx_order_err = 1'b0
);

    localparam [31:0] FILLER = 32'h66665555;

    // -------------------------------------------------------------------------
    // Pads. c180 OLOGIC registers are FDPE on one shared PRE net (rst_c180),
    // so OFF and TFF can share an OLOGIC (DRC AVAL-250). Inputs are ILOGIC FDRE
    // on c0 with no reset.
    // -------------------------------------------------------------------------
    wire rst_c180;
    xpm_cdc_async_rst #(
        .DEST_SYNC_FF       ( 4 ),
        .INIT_SYNC_FF       ( 0 ),
        .RST_ACTIVE_HIGH    ( 1 )
    ) i_cdc_rst_c180 (
        .src_arst           ( arst          ),
        .dest_clk           ( c180          ),
        .dest_arst          ( rst_c180      )
    );

    // c0 issue registers. Each feeds its OLOGIC D pin directly.
    (* IOB = "FALSE" *) reg        o_t    = 1'b1;     // 1 = release DATA/BE
    (* IOB = "FALSE" *) reg        o_oe_n = 1'b1;
    (* IOB = "FALSE" *) reg        o_rd_n = 1'b1;
    (* IOB = "FALSE" *) reg        o_wr_n = 1'b1;
    (* IOB = "FALSE" *) reg [31:0] o_d    = 32'h0;

    // FIFO words are byte-swapped on the bus, as in pcileech_ft601.
    wire [31:0] o_d_bus = {o_d[7:0], o_d[15:8], o_d[23:16], o_d[31:24]};
    wire [31:0] pad_in;
    wire [31:0] in_d;
    wire        in_rxf_n, in_txe_n;

    genvar i;
    generate
        for ( i = 0; i < 32; i = i + 1 ) begin : g_data
            wire q_o, q_t;
            (* IOB = "TRUE" *)
            FDPE #( .INIT ( 1'b1 ) ) i_off (
                .C ( c180 ), .CE ( 1'b1 ), .PRE ( rst_c180 ), .D ( o_d_bus[i] ), .Q ( q_o ) );
            (* IOB = "TRUE", KEEP = "TRUE" *)
            FDPE #( .INIT ( 1'b1 ) ) i_tff (
                .C ( c180 ), .CE ( 1'b1 ), .PRE ( rst_c180 ), .D ( o_t ), .Q ( q_t ) );
            IOBUF i_iobuf (
                .IO ( FT601_DATA[i] ), .I ( q_o ), .T ( q_t ), .O ( pad_in[i] ) );
            (* IOB = "TRUE" *)
            FDRE #( .INIT ( 1'b0 ) ) i_ifd (
                .C ( c0 ), .CE ( 1'b1 ), .R ( 1'b0 ), .D ( pad_in[i] ), .Q ( in_d[i] ) );
        end
        for ( i = 0; i < 4; i = i + 1 ) begin : g_be
            wire q_t;
            (* IOB = "TRUE", KEEP = "TRUE" *)
            FDPE #( .INIT ( 1'b1 ) ) i_tff (
                .C ( c180 ), .CE ( 1'b1 ), .PRE ( rst_c180 ), .D ( o_t ), .Q ( q_t ) );
            OBUFT i_obuft ( .O ( FT601_BE[i] ), .I ( 1'b1 ), .T ( q_t ) );
        end
    endgenerate

    (* IOB = "TRUE" *)
    FDPE #( .INIT ( 1'b1 ) ) i_oe_off (
        .C ( c180 ), .CE ( 1'b1 ), .PRE ( rst_c180 ), .D ( o_oe_n ), .Q ( FT601_OE_N ) );
    (* IOB = "TRUE" *)
    FDPE #( .INIT ( 1'b1 ) ) i_rd_off (
        .C ( c180 ), .CE ( 1'b1 ), .PRE ( rst_c180 ), .D ( o_rd_n ), .Q ( FT601_RD_N ) );
    (* IOB = "TRUE" *)
    FDPE #( .INIT ( 1'b1 ) ) i_wr_off (
        .C ( c180 ), .CE ( 1'b1 ), .PRE ( rst_c180 ), .D ( o_wr_n ), .Q ( FT601_WR_N ) );
    (* IOB = "TRUE" *)
    FDRE #( .INIT ( 1'b1 ) ) i_rxf_ifd (
        .C ( c0 ), .CE ( 1'b1 ), .R ( 1'b0 ), .D ( FT601_RXF_N ), .Q ( in_rxf_n ) );
    (* IOB = "TRUE" *)
    FDRE #( .INIT ( 1'b1 ) ) i_txe_ifd (
        .C ( c0 ), .CE ( 1'b1 ), .R ( 1'b0 ), .D ( FT601_TXE_N ), .Q ( in_txe_n ) );

    assign FT601_SIWU_N = 1'b1;

    // Control state (see the control block below).
    localparam [2:0] S_GUARD  = 3'd0,   // pads released, waiting to drive
                     S_IDLE   = 3'd1,   // FPGA drives DATA/BE
                     S_RX_REL = 3'd2,   // pads released, OE_N next
                     S_RX_OE  = 3'd3,   // OE_N issued, RD_N next
                     S_RX     = 3'd4,   // OE_N and RD_N issued
                     S_TX     = 3'd5,   // issuing WR_N + data
                     S_TX_END = 3'd6;   // last write result arrives
    reg [2:0] state     = S_GUARD;
    reg [3:0] guard_cnt = 4'd0;
    reg       tx_refused = 1'b0;

    // Issued strobes as the FT601 saw them at the edge of the current sample.
    reg rd_d1 = 1'b1;
    reg wr_d1 = 1'b1;
    always @ ( posedge c0 ) begin
        rd_d1 <= rst ? 1'b1 : o_rd_n;
        wr_d1 <= rst ? 1'b1 : o_wr_n;
    end

    // -------------------------------------------------------------------------
    // RX: one word per edge where the FT601 saw RD_N low with RXF_N low.
    // -------------------------------------------------------------------------
    always @ ( posedge c0 ) begin
        dout_valid <= !rst && !in_rxf_n && !rd_d1;
        dout       <= {in_d[7:0], in_d[15:8], in_d[23:16], in_d[31:24]};
    end

    // -------------------------------------------------------------------------
    // TX queue. wp: next write, ip: next issue, ap: oldest unaccepted.
    // -------------------------------------------------------------------------
    localparam integer QW = 4;                  // 16 entries
    reg [31:0]  q_mem [0:(1<<QW)-1];
    reg [QW:0]  wp = 0, ip = 0, ap = 0;
    wire [QW:0] q_used = wp - ap;

    // Two FIFO reads can be in flight (rd_en this cycle and last cycle), and a
    // filler may be written instead of a FIFO word; requesting only while
    // q_used <= 12 keeps every write inside the 16 entries.
    assign din_req_data = !rst && (q_used <= 12);

    // Filler words, as pcileech_ft601: five on reset and five whenever the
    // queue has been empty for 16 cycles. Written only when no FIFO word is.
    reg [3:0] idle_cnt    = 4'd0;
    reg [2:0] filler_left = 3'd5;
    wire      q_wr_filler = !din_wr_en && (filler_left != 0) && (q_used <= 8);
    wire      q_wr        = din_wr_en || q_wr_filler;

    always @ ( posedge c0 )
        if ( q_wr )
            q_mem[wp[QW-1:0]] <= din_wr_en ? din : FILLER;

    // -------------------------------------------------------------------------
    // Control.
    // -------------------------------------------------------------------------

    wire tx_accept = !wr_d1 && !in_txe_n;
    wire tx_refuse = !wr_d1 &&  in_txe_n;
    wire q_unissued = (ip != wp);

    always @ ( posedge c0 )
        if ( rst ) begin
            state        <= S_GUARD;
            guard_cnt    <= 4'd0;
            o_t          <= 1'b1;
            o_oe_n       <= 1'b1;
            o_rd_n       <= 1'b1;
            o_wr_n       <= 1'b1;
            wp           <= 0;
            ip           <= 0;
            ap           <= 0;
            tx_refused   <= 1'b0;
            idle_cnt     <= 4'd0;
            filler_left  <= 3'd5;
            tx_order_err <= 1'b0;
        end
        else begin
            // Queue writes and fillers.
            if ( q_wr )
                wp <= wp + 1'b1;
            if ( q_wr_filler )
                filler_left <= filler_left - 3'd1;
            idle_cnt <= ( (q_used != 0) || din_wr_en ) ? 4'd0 : idle_cnt + 4'd1;
            if ( (idle_cnt == 4'hf) && (filler_left == 0) )
                filler_left <= 3'd5;

            // Write results, in issue order, two cycles after each issue.
            if ( tx_accept ) begin
                if ( tx_refused )
                    tx_order_err <= 1'b1;
                else
                    ap <= ap + 1'b1;
            end
            if ( tx_refuse )
                tx_refused <= 1'b1;

            o_wr_n <= 1'b1;
            case ( state )
                S_GUARD: begin
                    o_t <= 1'b1;
                    if ( !in_rxf_n ) begin
                        o_oe_n <= 1'b0;             // pads already released
                        state  <= S_RX_OE;
                    end
                    else if ( guard_cnt == 4'(GUARD_CYCLES - 1) ) begin
                        o_t   <= 1'b0;
                        state <= S_IDLE;
                    end
                    guard_cnt <= guard_cnt + 4'd1;
                end
                S_IDLE: begin
                    if ( !in_rxf_n ) begin          // RX has priority
                        o_t   <= 1'b1;
                        state <= S_RX_REL;
                    end
                    else if ( !in_txe_n && q_unissued ) begin
                        o_d    <= q_mem[ip[QW-1:0]];
                        o_wr_n <= 1'b0;
                        ip     <= ip + 1'b1;
                        state  <= S_TX;
                    end
                end
                S_RX_REL: begin
                    o_oe_n <= 1'b0;
                    state  <= S_RX_OE;
                end
                S_RX_OE: begin
                    o_rd_n <= 1'b0;
                    state  <= S_RX;
                end
                S_RX:
                    if ( in_rxf_n ) begin
                        o_oe_n    <= 1'b1;
                        o_rd_n    <= 1'b1;
                        guard_cnt <= 4'd0;
                        state     <= S_GUARD;
                    end
                S_TX:
                    if ( tx_refuse || tx_refused || !q_unissued )
                        state <= S_TX_END;
                    else begin
                        o_d    <= q_mem[ip[QW-1:0]];
                        o_wr_n <= 1'b0;
                        ip     <= ip + 1'b1;
                    end
                S_TX_END: begin
                    // The last write was issued two edges ago; its result is
                    // tx_accept/tx_refuse now. Rewind to the oldest unaccepted
                    // word if anything was refused.
                    ip         <= ( tx_refuse || tx_refused ) ? ap : ip;
                    tx_refused <= 1'b0;
                    state      <= S_IDLE;
                end
                default:
                    state <= S_GUARD;
            endcase
        end

    // synthesis translate_off
    always @ ( posedge c0 )
        if ( !rst && tx_accept && tx_refused )
            $error("FT601 accepted a write after refusing an earlier one");
    // synthesis translate_on

endmodule
/* verilator lint_on PROCASSINIT */
