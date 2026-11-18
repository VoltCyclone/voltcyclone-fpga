// pcileech_mux output integrity under a toggling consumer ready (rd_en).
//
// Ports answer a pull (p*_req_data in n) in n+1, as on the board: p3..p6 carry
// a TLP beat (1..4 DWs, contiguous from p3), p0..p2 answer sparsely, p7 is
// unused. That bounds the input at 7 DWs per cycle, the mux output capacity
// (the mux has no other backpressure). DWs are numbered globally in port order. The consumer raises/lowers rd_en at
// random (on the board rd_en is com_din_ready, which falls on COM TX FIFO
// almost-full) and writes a word whenever valid is high, as the COM TX FIFO
// does. Every DW must come out exactly once, in order, with its ctx/tag; valid
// must never be high while rd_en is low. Filler words (tag 2'b11) are skipped.
//
// RD_MODE 0: rd_en random per cycle; 1: long runs (almost-full-like);
//         2: always high (control: stock passes this).
// PASS marker: MUX_READY_PASS.
`timescale 1ns / 1ps
module tb_mux_ready;
    parameter integer SEED    = 1;
    parameter integer RD_MODE = 0;
    parameter integer CYCLES  = 200000;

    integer rng = SEED;
    function automatic integer rnd(input integer n);
        rnd = ($random(rng) & 32'h7fffffff) % n;
    endfunction

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg rd_en = 1'b0;

    wire [255:0] dout;
    wire         valid;
    wire [7:0]   req;
    reg  [7:0]   wr = 0;
    reg  [31:0]  din [8];
    reg  [1:0]   ctx [8];
    reg  [31:0]  seq = 0;            // next DW number to issue
    integer      p_on = 70;          // per-port answer probability

    pcileech_mux dut(
        .clk(clk), .rst(rst), .dout(dout), .valid(valid), .rd_en(rd_en),
        .p0_din(din[0]), .p0_tag(2'b00), .p0_ctx(ctx[0]), .p0_wr_en(wr[0]), .p0_req_data(req[0]),
        .p1_din(din[1]), .p1_tag(2'b00), .p1_ctx(ctx[1]), .p1_wr_en(wr[1]), .p1_req_data(req[1]),
        .p2_din(din[2]), .p2_tag(2'b00), .p2_ctx(ctx[2]), .p2_wr_en(wr[2]), .p2_req_data(req[2]),
        .p3_din(din[3]), .p3_tag(2'b00), .p3_ctx(ctx[3]), .p3_wr_en(wr[3]), .p3_req_data(req[3]),
        .p4_din(din[4]), .p4_tag(2'b00), .p4_ctx(ctx[4]), .p4_wr_en(wr[4]), .p4_req_data(req[4]),
        .p5_din(din[5]), .p5_tag(2'b00), .p5_ctx(ctx[5]), .p5_wr_en(wr[5]), .p5_req_data(req[5]),
        .p6_din(din[6]), .p6_tag(2'b00), .p6_ctx(ctx[6]), .p6_wr_en(wr[6]), .p6_req_data(req[6]),
        .p7_din(din[7]), .p7_tag(2'b00), .p7_ctx(ctx[7]), .p7_wr_en(wr[7]), .p7_req_data(req[7])
    );

    // Sources: answer a pull in the next cycle (registered), numbering DWs in
    // port order so the expected output order is simply ascending.
    always @ ( posedge clk ) begin : src
        integer p;
        integer n;
        reg [7:0] en;
        en = 8'b0;
        if ( !rst && req[0] ) begin
            en[0] = rnd(100) < p_on / 10;
            en[1] = rnd(100) < p_on / 10;
            en[2] = rnd(100) < p_on / 10;
            if ( rnd(100) < p_on ) begin
                n = 1 + rnd(4);
                en[3] = 1'b1; en[4] = n > 1; en[5] = n > 2; en[6] = n > 3;
            end
        end
        for ( p = 0; p < 8; p = p + 1 ) begin
            wr[p] <= en[p];
            if ( en[p] ) begin
                din[p] <= seq;
                ctx[p] <= seq[1:0] ^ seq[3:2];
                seq     = seq + 1;
            end
        end
    end

    // Consumer.
    integer run_left = 0;
    always @ ( posedge clk ) begin
        if ( RD_MODE == 2 )
            rd_en <= !rst;
        else if ( RD_MODE == 1 ) begin
            if ( run_left == 0 ) begin
                rd_en   <= !rst && !rd_en;
                run_left = 1 + rnd(rd_en ? 6 : 40);
            end
            else
                run_left = run_left - 1;
        end
        else
            rd_en <= !rst && rnd(100) < 65;
    end

    integer errors = 0, got = 0, words = 0;
    reg [31:0] expect_seq = 0;
    always @ ( posedge clk ) begin : chk
        integer s;
        reg [3:0]  cx;
        reg [31:0] dw;
        if ( valid && !rd_en ) begin
            $display("MUX_VALID_NOT_READY t=%0t", $time); errors = errors + 1;
        end
        if ( valid ) begin
            words = words + 1;
            for ( s = 0; s < 7; s = s + 1 ) begin
                case ( s )
                    0: cx = dout[251:248]; 1: cx = dout[255:252];
                    2: cx = dout[243:240]; 3: cx = dout[247:244];
                    4: cx = dout[235:232]; 5: cx = dout[239:236];
                    default: cx = dout[227:224];
                endcase
                dw = dout[223 - 32*s -: 32];
                if ( cx[1:0] != 2'b11 ) begin
                    if ( dw !== expect_seq || cx[3:2] !== (dw[1:0] ^ dw[3:2]) ) begin
                        if ( errors < 10 )
                            $display("MUX_ORDER t=%0t got=%0d exp=%0d ctx=%b", $time, dw, expect_seq, cx[3:2]);
                        errors = errors + 1;
                        expect_seq = dw;      // resynchronise to keep counting
                    end
                    expect_seq = expect_seq + 1;
                    got = got + 1;
                end
            end
        end
    end

    initial begin
        repeat ( 5 ) @( posedge clk );
        rst <= 1'b0;
        repeat ( CYCLES ) @( posedge clk );
        p_on = 0;                              // stop sources, drain
        repeat ( 20 ) @( posedge clk );
        force rd_en = 1'b1;
        repeat ( 200 ) @( posedge clk );
        if ( got != seq ) begin
            $display("MUX_INCOMPLETE got=%0d issued=%0d", got, seq); errors = errors + 1;
        end
        if ( errors == 0 ) $display("MUX_READY_PASS seed=%0d mode=%0d dws=%0d words=%0d", SEED, RD_MODE, got, words);
        else $display("MUX_READY_FAIL seed=%0d mode=%0d errors=%0d dws=%0d issued=%0d", SEED, RD_MODE, errors, got, seq);
        $finish;
    end
endmodule
