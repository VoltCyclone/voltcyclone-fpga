// Behavioral stand-in for xpm_cdc_handshake (DEST_EXT_HSK=0), SIMULATION ONLY.
// Not the AMD source and never synthesized. Copied from the reset/CDC draft's
// scratch model: source data captured while src_send is low and held while it
// is high; the first stage of each synchronizer sometimes resolves one cycle
// late (+define+XPM_NO_JITTER disables). Usage-rule violations fail the run.
`timescale 1ns / 1ps

module xpm_cdc_jitter_ff (input clk, input d, output reg q);
    initial q = 1'b0;
    always @ ( posedge clk ) begin
`ifndef XPM_NO_JITTER
        if ( (d !== q) && ($urandom % 2) )
            q <= q;
        else
`endif
            q <= d;
    end
endmodule

module xpm_cdc_handshake #(
    parameter integer DEST_EXT_HSK   = 1,
    parameter integer DEST_SYNC_FF   = 4,
    parameter integer INIT_SYNC_FF   = 0,
    parameter integer SIM_ASSERT_CHK = 0,
    parameter integer SRC_SYNC_FF    = 4,
    parameter integer WIDTH          = 1
) (
    input                   src_clk,
    input  [WIDTH-1:0]      src_in,
    input                   src_send,
    output                  src_rcv,
    input                   dest_clk,
    output reg [WIDTH-1:0]  dest_out = '0,
    output reg              dest_req = 1'b0,
    input                   dest_ack
);
    initial if ( DEST_EXT_HSK != 0 ) begin $display("XPM_MODEL_ERROR: only DEST_EXT_HSK=0 modeled"); $fatal; end

    // ---- source ----
    reg              src_sendd_ff = 1'b0;
    reg [WIDTH-1:0]  src_hsdata_ff = '0;
    always @ ( posedge src_clk ) begin
        src_sendd_ff  <= src_send;
        if ( !src_sendd_ff )
            src_hsdata_ff <= src_in;
    end

    // ---- request synchronizer -> dest ----
    wire r0;
    xpm_cdc_jitter_ff i_r0 (.clk(dest_clk), .d(src_sendd_ff), .q(r0));
    reg [DEST_SYNC_FF-2:0] rst_ = '0;
    always @ ( posedge dest_clk ) rst_ <= {rst_, r0};
    wire dest_req_ff = rst_[DEST_SYNC_FF-2];
    reg  dest_req_ff_d = 1'b0;
    always @ ( posedge dest_clk ) begin
        dest_req_ff_d <= dest_req_ff;
        dest_req      <= dest_req_ff && !dest_req_ff_d;
        if ( dest_req_ff && !dest_req_ff_d )
            dest_out  <= src_hsdata_ff;
    end

    // ---- ack synchronizer -> src (internal ack = synchronized request level) ----
    wire a0;
    xpm_cdc_jitter_ff i_a0 (.clk(src_clk), .d(dest_req_ff), .q(a0));
    reg [SRC_SYNC_FF-2:0] ast = '0;
    always @ ( posedge src_clk ) ast <= {ast, a0};
    assign src_rcv = ast[SRC_SYNC_FF-2];

    // ---- usage-rule checks (fail the simulation) ----
    reg              prev_send = 1'b0;
    reg [WIDTH-1:0]  prev_in;
    reg              prev_rcv = 1'b0;
    always @ ( posedge src_clk ) begin
        if ( src_send && !prev_send && prev_rcv )
            begin $display("XPM_MODEL_ERROR %m @%0t: src_send asserted while src_rcv high", $time); $fatal; end
        if ( !src_send && prev_send && !prev_rcv )
            begin $display("XPM_MODEL_ERROR %m @%0t: src_send dropped before src_rcv", $time); $fatal; end
        if ( src_send && prev_send && !prev_rcv && (src_in !== prev_in) )
            begin $display("XPM_MODEL_ERROR %m @%0t: src_in changed during handshake", $time); $fatal; end
        prev_send <= src_send;
        prev_in   <= src_in;
        prev_rcv  <= src_rcv;
    end
    // The bus the destination samples must still be the data launched with the
    // request. NB the ack here is taken from the request synchronizer output, i.e.
    // it can reach the source one dest edge BEFORE capture (pessimistic vs. an
    // ack registered at the capture edge), so the design must keep the data
    // stable until src_rcv has fallen again.
    reg [WIDTH-1:0] launched;
    always @ ( posedge src_clk ) if ( src_send && !src_sendd_ff ) launched <= src_hsdata_ff;
    always @ ( posedge dest_clk )
        if ( dest_req_ff && !dest_req_ff_d && (src_hsdata_ff !== launched) )
            begin $display("XPM_MODEL_ERROR %m @%0t: source data moved before dest capture", $time); $fatal; end
endmodule
