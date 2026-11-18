//
// PCILeech FPGA.
//
// Merge multiple 32-bit words into a 256-bit word consisting of one (1) 32-bit
// status word and seven (7) data words. This is done to enable relatively
// efficient transmission over the FT601 together with some additional info.
//
// (c) Ulf Frisk, 2017-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps

module pcileech_mux(
    input                clk,
    input                rst,
    // output
    output [255:0]       dout,
    output               valid,
    input                rd_en,
    // port0: input highest priority
    input  [31:0]        p0_din,
    input  [1:0]         p0_tag,
    input  [1:0]         p0_ctx,
    input                p0_wr_en,
    output               p0_req_data,
    // port1:
    input  [31:0]        p1_din,
    input  [1:0]         p1_tag,
    input  [1:0]         p1_ctx,
    input                p1_wr_en,
    output               p1_req_data,
    // port2:
    input  [31:0]        p2_din,
    input  [1:0]         p2_tag,
    input  [1:0]         p2_ctx,
    input                p2_wr_en,
    output               p2_req_data,
    // port3:
    input  [31:0]        p3_din,
    input  [1:0]         p3_tag,
    input  [1:0]         p3_ctx,
    input                p3_wr_en,
    output               p3_req_data,
    // port4:
    input  [31:0]        p4_din,
    input  [1:0]         p4_tag,
    input  [1:0]         p4_ctx,
    input                p4_wr_en,
    output               p4_req_data,
    // port5:
    input  [31:0]        p5_din,
    input  [1:0]         p5_tag,
    input  [1:0]         p5_ctx,
    input                p5_wr_en,
    output               p5_req_data,
    // port6:
    input  [31:0]        p6_din,
    input  [1:0]         p6_tag,
    input  [1:0]         p6_ctx,
    input                p6_wr_en,
    output               p6_req_data,
    // port7:
    input  [31:0]        p7_din,
    input  [1:0]         p7_tag,
    input  [1:0]         p7_ctx,
    input                p7_wr_en,
    output               p7_req_data
    );

    // 'en' is delayed 1CLK so it's in synch with inputs.
    //      output integrity is handled by extra register.
    reg en;
    always @ ( posedge clk )
        en <= rd_en && !rst;

    // Input register: port answers are registered once before the index
    // ripple, so the ripple starts from flip-flops rather than from the
    // ports' own output logic (the dst FIFO lane gate was the worst net_clk
    // path). The per-port prefix counts are registered with them, so each
    // port's write index is one add (idx_base + q_pre[k]) instead of an
    // eight-stage ripple. Everything below runs one cycle later, on en_q and q_*.
    reg         en_q = 1'b0;
    reg  [7:0]  q_wr = 8'h00;
    reg  [3:0]  q_pre [9];                      // q_pre[k] = written ports below k
    reg  [31:0] q_din [8];
    reg  [3:0]  q_ct  [8];                      // {ctx, tag}
    wire [7:0]  in_wr = (en && !rst) ? {p7_wr_en, p6_wr_en, p5_wr_en, p4_wr_en, p3_wr_en, p2_wr_en, p1_wr_en, p0_wr_en} : 8'h00;
    always @ ( posedge clk ) begin : in_reg
        integer k;
        en_q <= en && !rst;
        q_wr <= in_wr;
        for ( k = 0; k < 9; k = k + 1 )
            q_pre[k] <= 4'($countones({1'b0, in_wr} & ((9'h001 << k) - 9'h001)));
        q_din[0] <= p0_din;  q_ct[0] <= {p0_ctx, p0_tag};
        q_din[1] <= p1_din;  q_ct[1] <= {p1_ctx, p1_tag};
        q_din[2] <= p2_din;  q_ct[2] <= {p2_ctx, p2_tag};
        q_din[3] <= p3_din;  q_ct[3] <= {p3_ctx, p3_tag};
        q_din[4] <= p4_din;  q_ct[4] <= {p4_ctx, p4_tag};
        q_din[5] <= p5_din;  q_ct[5] <= {p5_ctx, p5_tag};
        q_din[6] <= p6_din;  q_ct[6] <= {p6_ctx, p6_tag};
        q_din[7] <= p7_din;  q_ct[7] <= {p7_ctx, p7_tag};
    end

    assign p0_req_data = rd_en;
    assign p1_req_data = rd_en;
    assign p2_req_data = rd_en;
    assign p3_req_data = rd_en;
    assign p4_req_data = rd_en;
    assign p5_req_data = rd_en;
    assign p6_req_data = rd_en;
    assign p7_req_data = rd_en;

    reg [31:0]  data_reg[14];
    reg [3:0]   ctx_reg[14];

    wire        p8_wr_en;
    reg [3:0]   idx_base;
    wire [3:0]  p0_idx = idx_base;
    wire [3:0]  p1_idx = idx_base + q_pre[1];
    wire [3:0]  p2_idx = idx_base + q_pre[2];
    wire [3:0]  p3_idx = idx_base + q_pre[3];
    wire [3:0]  p4_idx = idx_base + q_pre[4];
    wire [3:0]  p5_idx = idx_base + q_pre[5];
    wire [3:0]  p6_idx = idx_base + q_pre[6];
    wire [3:0]  p7_idx = idx_base + q_pre[7];
    wire [3:0]  p8_idx = idx_base + q_pre[8];   // idle port
    wire [3:0] idx_max = p8_idx + p8_wr_en;     // max index

    // P8: INTERNAL "IDLE PORT"
    reg [3:0]   idle_count;
    wire [31:0] p8_din = 32'hffffffff;
    wire [1:0]  p8_tag = 2'b11;
    wire [1:0]  p8_ctx = 2'b11;
    assign      p8_wr_en = en_q && (idx_base > 0) && (idle_count > 7) && (q_pre[8] == 4'd0);
    
    
    
    // Output queue. Ports are pulled while rd_en is high and answer one cycle
    // later (en); the answer is registered (en_q) and a word completes the
    // cycle after that (dout_valid), so up to three words can still complete
    // after rd_en falls. Every completed
    // word is queued and leaves only while rd_en is high, in order. (The
    // previous single buffer loaded only while en was low: a word completing
    // as rd_en fell was dropped, and the buffered word was presented twice
    // when rd_en rose while en was still low.)
    reg             dout_valid;
    wire [255:0]    dout_data = { ctx_reg[1], ctx_reg[0], ctx_reg[3], ctx_reg[2], ctx_reg[5], ctx_reg[4], 4'hE, ctx_reg[6], data_reg[0], data_reg[1], data_reg[2], data_reg[3], data_reg[4], data_reg[5], data_reg[6] };
    reg [255:0]     oq [0:7];
    reg [2:0]       oq_rd;
    reg [2:0]       oq_wr;
    reg [3:0]       oq_cnt;
    wire            oq_pop = rd_en && (oq_cnt != 4'd0);
    assign valid = oq_pop;
    assign dout  = oq[oq_rd];
    
    
    
    always @ ( posedge clk ) begin
        if( rst )
            begin
                idx_base <= 0;
                idle_count <= 0;
                dout_valid <= 0;
                oq_rd <= 0;
                oq_wr <= 0;
                oq_cnt <= 0;
            end
        else
            begin
                // OUTPUT QUEUE:
                if( dout_valid ) begin
                    oq[oq_wr] <= dout_data;
                    oq_wr <= oq_wr + 1;
                end
                if( oq_pop )
                    oq_rd <= oq_rd + 1;
                oq_cnt <= oq_cnt + {3'b0, dout_valid} - {3'b0, oq_pop};
`ifndef SYNTHESIS
`ifndef FORMAL
                if( dout_valid && !oq_pop && (oq_cnt == 4'd8) )
                    $fatal(1, "PCILEECH_MUX_OQ_OVERFLOW");
`endif
`endif
            
                // OUTPUT VALID:
                dout_valid <= en_q && (idx_max >= 7);
                
                if( en_q ) begin
                    // NEXT INDEX BASE:
                    idx_base <= idx_max - ((idx_max >= 7) ? 7 : 0);
                    // IDLE COUNT:
                    idle_count <= ((idx_base > 0) && (q_pre[8] == 4'd0)) ? (idle_count + 1) : 0;
                    // DATA/CTX writes into index [0-8]:
                    if( q_wr[0] ) begin  data_reg[p0_idx] <= q_din[0];  ctx_reg[p0_idx] <= q_ct[0];  end
                    if( q_wr[1] ) begin  data_reg[p1_idx] <= q_din[1];  ctx_reg[p1_idx] <= q_ct[1];  end
                    if( q_wr[2] ) begin  data_reg[p2_idx] <= q_din[2];  ctx_reg[p2_idx] <= q_ct[2];  end
                    if( q_wr[3] ) begin  data_reg[p3_idx] <= q_din[3];  ctx_reg[p3_idx] <= q_ct[3];  end
                    if( q_wr[4] ) begin  data_reg[p4_idx] <= q_din[4];  ctx_reg[p4_idx] <= q_ct[4];  end
                    if( q_wr[5] ) begin  data_reg[p5_idx] <= q_din[5];  ctx_reg[p5_idx] <= q_ct[5];  end
                    if( q_wr[6] ) begin  data_reg[p6_idx] <= q_din[6];  ctx_reg[p6_idx] <= q_ct[6];  end
                    if( q_wr[7] ) begin  data_reg[p7_idx] <= q_din[7];  ctx_reg[p7_idx] <= q_ct[7];  end
                    if( p8_wr_en ) begin  data_reg[p8_idx] <= p8_din;  ctx_reg[p8_idx] <= {p8_ctx, p8_tag};  end
                end
                
                if( dout_valid ) begin
                    // DATA/CTX previous move:
                    if( idx_base > 0) begin  data_reg[0] <= data_reg[7+0];  ctx_reg[0] <= ctx_reg[7+0];  end
                    if( idx_base > 1) begin  data_reg[1] <= data_reg[7+1];  ctx_reg[1] <= ctx_reg[7+1];  end
                    if( idx_base > 2) begin  data_reg[2] <= data_reg[7+2];  ctx_reg[2] <= ctx_reg[7+2];  end
                    if( idx_base > 3) begin  data_reg[3] <= data_reg[7+3];  ctx_reg[3] <= ctx_reg[7+3];  end
                    if( idx_base > 4) begin  data_reg[4] <= data_reg[7+4];  ctx_reg[4] <= ctx_reg[7+4];  end
                    if( idx_base > 5) begin  data_reg[5] <= data_reg[7+5];  ctx_reg[5] <= ctx_reg[7+5];  end
                    if( idx_base > 6) begin  data_reg[6] <= data_reg[7+6];  ctx_reg[6] <= ctx_reg[7+6];  end
                end
                

            end
    end
`ifdef FORMAL
`ifndef PCILEECH_MUX_OQ_BOUND
`define PCILEECH_MUX_OQ_BOUND 4
`endif
    // Queue bound for any rd_en and port write pattern (prove_mux_oq.py).
    reg f_past = 1'b0;
    always @ ( posedge clk ) f_past <= 1'b1;
    always @ ( * ) if ( !f_past ) assume( rst );
    always @ ( posedge clk ) if ( f_past && !rst ) assert( oq_cnt <= `PCILEECH_MUX_OQ_BOUND );
`endif
endmodule
