`timescale 1ns / 1ps
module tb_req_np_cap;
    reg clk=0, rst=1, link_up=0;
    reg [7:0] nph=0;
    wire [8:0] np_cap;
    integer checks=0;
    pcileech_req_np_cap dut(.clk(clk), .rst(rst), .link_up(link_up),
                           .fc_nph(nph), .np_cap(np_cap));
    always #5 clk=~clk;
    initial begin #100000; $fatal(1,"R1_TB_FAIL watchdog"); end
    task automatic step;
        @(posedge clk); #1;
    endtask
    task automatic check(input [8:0] want);
        checks=checks+1;
        if(np_cap !== want) $fatal(1,"R1_TB_FAIL cap=%d want=%d",np_cap,want);
    endtask
    task automatic session(input [7:0] credit, input [8:0] want);
        @(negedge clk); link_up=0; rst=1; nph=credit;
        step(); check(0);
        @(negedge clk); rst=0;
        repeat(3) begin step(); check(0); end
        @(negedge clk); link_up=1;
        step(); check(0);
        step(); check(0);
        step(); check(want);
        // The core's 101 count is cumulative: never resample it in-session.
        @(negedge clk); nph=255;
        repeat(6) begin step(); check(want); end
        // Link loss invalidates the cap without needing a subsystem reset.
        @(negedge clk); link_up=0; #1; check(0);
        step(); check(0);
    endtask
    initial begin
        @(negedge clk); rst=0; link_up=1; nph=8'bxxxxxxxx;
        repeat(6) begin step(); check(0); end
        @(negedge clk); nph=8'bzzzzzzzz;
        repeat(3) begin step(); check(0); end
        @(negedge clk); nph=2;
        step(); check(70);
        session(0,35); session(1,35); session(2,70); session(3,105);
        session(4,140); session(5,175); session(6,210); session(7,245);
        for(integer c=8;c<256;c=c+1) session(8'(c),256);
        // Core reset alone starts a new session even if link_up stays high.
        @(negedge clk); link_up=1; nph=2;
        repeat(3) step(); check(70);
        @(negedge clk); rst=1; #1; check(0);
        step(); check(0);
        @(negedge clk); rst=0; nph=3;
        step(); check(0); step(); check(0); step(); check(105);
        $display("R1_TB_PASS tb_req_np_cap checks=%0d",checks);
        $finish;
    end
endmodule
