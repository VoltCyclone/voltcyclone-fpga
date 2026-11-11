//
// PCILeech FPGA.
//
// FT601 / FT245 controller module (v4).
//
// (c) Ulf Frisk, 2017-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps

module pcileech_ft601(
    input               clk,
    input               rst,
    // TO/FROM PADS
    output [3:0]        FT601_BE,
    inout [31:0]        FT601_DATA,
    input               FT601_RXF_N,
    input               FT601_TXE_N,
    output bit          FT601_OE_N,
    output bit          FT601_RD_N,
    output bit          FT601_WR_N,
    output bit          FT601_SIWU_N,
    // TO/FROM FIFO
    output bit [31:0]   dout,
    output bit          dout_valid,
    input [31:0]        din,
    input               din_wr_en,
    output              din_req_data
    );
    
    initial begin
        FT601_OE_N   <= 1'b1;
        FT601_RD_N   <= 1'b1;
        FT601_WR_N   <= 1'b1;
        FT601_SIWU_N <= 1'b1;
        dout_valid   <= 1'b0;
        dout         <= 32'h00000000;
    end

    `define S_FT601_IDLE         4'h0
    `define S_FT601_RX_WAIT1     4'h2
    `define S_FT601_RX_WAIT2     4'h3
    `define S_FT601_RX_WAIT3     4'h4
    `define S_FT601_RX_ACTIVE    4'h5
    `define S_FT601_RX_COOLDOWN1 4'h6
    `define S_FT601_RX_COOLDOWN2 4'h7
    `define S_FT601_TX_WAIT1     4'h8
    `define S_FT601_TX_WAIT2     4'h9
    `define S_FT601_TX_ACTIVE    4'ha
    `define S_FT601_TX_COOLDOWN1 4'hb
    `define S_FT601_TX_COOLDOWN2 4'hc

    // Element 0 is reproduced by the g_ft601_data_off pad registers, which
    // drive the pads; FT601_DATA_OUT[0] itself has no remaining loads.
                        bit [31:0]      FT601_DATA_OUT[5];
    (* KEEP = "TRUE" *) wire            FWD;
    (* KEEP = "TRUE" *) bit [3:0]       data_cooldown_count = 0;
    (* KEEP = "TRUE" *) bit [2:0]       data_queue_count    = 0;     
    (* KEEP = "TRUE" *) bit [3:0]       state               = `S_FT601_IDLE;

    // Per-pin 3-state controls for FT601_DATA[31:0] (bits 31:0) and
    // FT601_BE[3:0] (bits 35:32). Each bit is !OE: 1 = release the pad,
    // 0 = FPGA drives it. Each bit feeds its OBUFT/IOBUF T pin directly, with
    // no inverter LUT in between, so it can be packed into the OLOGIC TFF.
    // Preserve the former OE register's cycle behavior and power-on drive
    // state, with inverted polarity. The old OE register and its multicycle
    // exception are removed; these outputs are timed as single-cycle paths.
    //   IOB           - request OLOGIC TFF packing.
    //   KEEP          - stop synthesis from merging the 36 identical
    //                   registers (merging is on by default, see Synth 8-3886)
    //                   back into one fabric FF.
    //   EXTRACT_RESET - keep rst in the D logic, not on the FF's set/reset
    //                   pin. The TFF shares the OLOGIC set/reset with the OFF
    //                   (g_ft601_data_off, R tied low), so it must not use it
    //                   either (DRC AVAL-250).
    // No DONT_TOUCH: the default opt_design does not merge equivalent drivers,
    // and DONT_TOUCH would also block phys_opt on these FFs.
    (* IOB = "TRUE", KEEP = "TRUE", EXTRACT_RESET = "NO" *)
                        bit [35:0]      ft601_t             = 36'h0;



    // -------------------------------------------------------------------------
    // FT245 RX / DATA INPUT BELOW:
    // -------------------------------------------------------------------------

    always @ ( posedge clk )
        begin
            dout_valid      <= !rst && !FT601_RXF_N && (state == `S_FT601_RX_ACTIVE);
            dout[7:0]       <= FT601_DATA[31:24];
            dout[15:8]      <= FT601_DATA[23:16];
            dout[23:16]     <= FT601_DATA[15:8];
            dout[31:24]     <= FT601_DATA[7:0];
        end



    // -------------------------------------------------------------------------
    // FT245 TX / DATA OUTPUT BELOW:
    // -------------------------------------------------------------------------        

    // Pad data registers (OLOGIC OFF). They mirror FT601_DATA_OUT[0] cycle for
    // cycle, with no set/reset pin in use, so each can share an OLOGIC with
    // its tristate FF (whose R is also tied low). The v2 routed build showed
    // the inferred FT601_DATA_OUT_reg[0][*] packed with S/R on the cooldown
    // reset net despite EXTRACT_RESET, which triggers DRC AVAL-250 and leaves
    // the data TFFs in fabric. An instantiated FDRE gives synthesis no reset
    // to extract. The reset load moves into D/CE:
    //   CE = reset load | shift from [1] | write of din into index 0
    //   D  = 32'h66665555 on reset, din on write to index 0, else [1]
    // This is the same priority as the FT601_DATA_OUT[0] logic below: reset,
    // then din (the last NBA wins), then shift, otherwise hold. Q drives only
    // the pad, so packing needs no replication.
    // INIT 0 matches the RTL power-on value of FT601_DATA_OUT[0] ('bit').
    wire        ft601_d0_rst  = rst || (data_cooldown_count == 4'hf);
    wire        ft601_d0_wr   = din_wr_en && ((data_queue_count - (FWD ? 3'b001 : 3'b000)) == 3'b000);
    wire        ft601_d0_shft = FWD && (data_queue_count > 1);
    wire        ft601_d0_ce   = ft601_d0_rst || ft601_d0_wr || ft601_d0_shft;
    wire [31:0] ft601_d0_d    = ft601_d0_rst ? 32'h66665555 : (ft601_d0_wr ? din : FT601_DATA_OUT[1]);
    wire [31:0] ft601_d0_q;
    wire [31:0] ft601_data_o  = {ft601_d0_q[7:0], ft601_d0_q[15:8], ft601_d0_q[23:16], ft601_d0_q[31:24]};
    genvar i;
    generate
        for ( i = 0; i < 32; i = i + 1 ) begin : g_ft601_data_off
            (* IOB = "TRUE" *)
            FDRE #( .INIT(1'b0) ) i_off (
                .C  ( clk               ),
                .CE ( ft601_d0_ce       ),
                .R  ( 1'b0              ),
                .D  ( ft601_d0_d[i]     ),
                .Q  ( ft601_d0_q[i]     )
            );
        end
    endgenerate
    generate
        for ( i = 0; i < 32; i = i + 1 ) begin : g_ft601_data_obuft
            assign FT601_DATA[i] = ft601_t[i] ? 1'bz : ft601_data_o[i];
        end
        for ( i = 0; i < 4; i = i + 1 ) begin : g_ft601_be_obuft
            assign FT601_BE[i]   = ft601_t[32 + i] ? 1'bz : 1'b1;
        end
    endgenerate
    assign din_req_data = !rst && (data_queue_count == 2) || (data_queue_count == 3);
    assign FWD          = !rst && !FT601_TXE_N && (data_queue_count != 0) && (state == `S_FT601_TX_ACTIVE);

    always @ ( posedge clk ) begin
        if ( rst || (data_cooldown_count == 4'hf) ) begin
            data_cooldown_count <= 0;
            data_queue_count    <= 5;
            FT601_DATA_OUT[0]   <= 32'h66665555;
            FT601_DATA_OUT[1]   <= 32'h66665555;
            FT601_DATA_OUT[2]   <= 32'h66665555;
            FT601_DATA_OUT[3]   <= 32'h66665555;
            FT601_DATA_OUT[4]   <= 32'h66665555;
        end
        else begin
            data_cooldown_count <= (data_queue_count == 0) ? (data_cooldown_count + 1) : 0;
            data_queue_count    <= data_queue_count + (din_wr_en ? 3'b001 : 3'b000) - (FWD ? 3'b001 : 3'b000);
            if ( FWD ) begin
                if ( data_queue_count > 1 ) begin
                    FT601_DATA_OUT[0] <= FT601_DATA_OUT[1];
                end
                if ( data_queue_count > 2 ) begin
                    FT601_DATA_OUT[1] <= FT601_DATA_OUT[2];
                end
                if ( data_queue_count > 3 ) begin
                    FT601_DATA_OUT[2] <= FT601_DATA_OUT[3];
                end
                if ( data_queue_count > 4 ) begin
                    FT601_DATA_OUT[3] <= FT601_DATA_OUT[4];
                end
            end
            if ( din_wr_en ) begin
                FT601_DATA_OUT[data_queue_count - (FWD ? 3'b001 : 3'b000)] <= din;
            end
        end
    end



    // -------------------------------------------------------------------------
    // FT245 main control below:
    // -------------------------------------------------------------------------

    always @ ( posedge clk )
        begin
            // Former OE next-state expression, inverted, into each per-pin TFF.
            ft601_t     <= {36{!(rst || FT601_RXF_N || ((state != `S_FT601_RX_ACTIVE) && (state != `S_FT601_RX_WAIT3) && (state != `S_FT601_RX_WAIT2) && (state != `S_FT601_RX_COOLDOWN1) && (state != `S_FT601_RX_COOLDOWN2)))}};
            FT601_OE_N  <=  (rst || FT601_RXF_N || ((state != `S_FT601_RX_ACTIVE) && (state != `S_FT601_RX_WAIT3) && (state != `S_FT601_RX_WAIT2)));
            FT601_RD_N  <=  (rst || FT601_RXF_N || ((state != `S_FT601_RX_ACTIVE) && (state != `S_FT601_RX_WAIT3)));
            FT601_WR_N  <=  !(!rst && !FT601_TXE_N && ((state == `S_FT601_TX_WAIT2) || ((state == `S_FT601_TX_ACTIVE) && (din_wr_en || (data_queue_count > 1)))));
        end

    always @ ( posedge clk )
        if ( rst )
            begin
                state <= `S_FT601_IDLE;
            end
        else case ( state )
            // ----------------------------------------------------------------
            // IDLE STATE:
            // RX are prioritized above TX in case both options are available. 
            // ----------------------------------------------------------------
            `S_FT601_IDLE:
                if ( !FT601_RXF_N )
                    state <= `S_FT601_RX_WAIT1;
                else if ( !FT601_TXE_N && (data_queue_count > 0) )
                    state <= `S_FT601_TX_WAIT1;
            // ----------------------------------------------------------------
            // RX DATA FROM THE FT601:
            // The receiver FIFO is assumed to always be non-full.
            // If receiver FIFO is full data will still be received but lost.
            // ----------------------------------------------------------------
            `S_FT601_RX_WAIT1:
                state <= FT601_RXF_N ? `S_FT601_RX_COOLDOWN1 : `S_FT601_RX_WAIT2;
            `S_FT601_RX_WAIT2:
                state <= FT601_RXF_N ? `S_FT601_RX_COOLDOWN1 : `S_FT601_RX_WAIT3;
            `S_FT601_RX_WAIT3:
                state <= FT601_RXF_N ? `S_FT601_RX_COOLDOWN1 : `S_FT601_RX_ACTIVE;
            `S_FT601_RX_ACTIVE:
                state <= FT601_RXF_N ? `S_FT601_RX_COOLDOWN1 : `S_FT601_RX_ACTIVE;
            `S_FT601_RX_COOLDOWN1:
                state <= `S_FT601_RX_COOLDOWN2;
            `S_FT601_RX_COOLDOWN2:
                state <= `S_FT601_IDLE;
            // ----------------------------------------------------------------
            // TX DATA TO THE FT601:
            // ----------------------------------------------------------------
            `S_FT601_TX_WAIT1:
                state <= FT601_TXE_N ? `S_FT601_TX_COOLDOWN1 : `S_FT601_TX_WAIT2;
            `S_FT601_TX_WAIT2:
                state <= FT601_TXE_N ? `S_FT601_TX_COOLDOWN1 : `S_FT601_TX_ACTIVE;
            `S_FT601_TX_ACTIVE:
                state <= (FT601_TXE_N || (!din_wr_en && (data_queue_count <= 1))) ? `S_FT601_TX_COOLDOWN1 : `S_FT601_TX_ACTIVE;
            `S_FT601_TX_COOLDOWN1:
                state <= `S_FT601_TX_COOLDOWN2;
            `S_FT601_TX_COOLDOWN2:
                state   <= `S_FT601_IDLE;
        endcase

endmodule
