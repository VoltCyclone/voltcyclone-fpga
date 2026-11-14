// Lockstep: pcileech_req_tagalloc (registered offer) vs tagalloc_registered_spec.sv
// on random free vectors, takes, range toggles and resets, including sparse and
// nearly-full vectors. Compares ports and all state every cycle.
`timescale 1ns / 1ps
module tb_req_tagalloc_spec;
    reg clk = 0, rst = 1, ext = 0, take = 0;
    reg [255:0] free = 0;
    wire av_r, av_s; wire [7:0] tg_r, tg_s;
    pcileech_req_tagalloc dut (.clk(clk), .rst(rst), .free(free), .ext_tag_en(ext),
                               .take(take), .avail(av_r), .tag(tg_r));
    req_tagalloc_spec     spec (.clk(clk), .rst(rst), .free(free), .ext_tag_en(ext),
                               .take(take), .avail(av_s), .tag(tg_s));
    always #5 clk = ~clk;
    integer n, k, takes = 0, wraps = 0, empties = 0, mode;
    initial begin
        repeat (2) @(posedge clk);
        for (n = 0; n < 300000; n = n + 1) begin
            @(negedge clk);
            rst = ($urandom % 4000) == 0;
            if ($urandom % 500 == 0) ext = ~ext;
            mode = (n / 5000) % 4;
            for (k = 0; k < 256; k = k + 1)
                case (mode)
                    0: free[k] = $urandom % 2;
                    1: free[k] = ($urandom % 64) == 0;          // sparse
                    2: free[k] = ($urandom % 64) != 0;          // nearly full
                    default: if ($urandom % 16 == 0) free[k] = ~free[k];
                endcase
            take = $urandom % 3 != 0;
            #1;
            if (av_r !== av_s || tg_r !== tg_s || dut.ptr !== spec.ptr ||
                dut.offer !== spec.offer || dut.offer_ok !== spec.offer_ok) begin
                $display("R1_TB_FAIL n=%0d rtl av=%b tag=%0d ptr=%0d spec av=%b tag=%0d ptr=%0d",
                         n, av_r, tg_r, dut.ptr, av_s, tg_s, spec.ptr);
                $fatal(1);
            end
            if (take && av_r) takes = takes + 1;
            if (take && av_r && tg_r < dut.ptr) wraps = wraps + 1;
            if (!av_r) empties = empties + 1;
        end
        $display("R1_TB_PASS tb_req_tagalloc_spec cycles=%0d takes=%0d wraps=%0d unavailable=%0d",
                 n, takes, wraps, empties);
        $finish;
    end
endmodule
