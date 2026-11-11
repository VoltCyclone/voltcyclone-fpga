// Self-checking bench for pcileech_req_tagalloc (MSIX_REQUESTER_CONTRACT.md section 5).
// Prints R1_TB_PASS on success.
`timescale 1ns / 1ps

module tb_req_tagalloc;
    reg          clk = 0, rst = 1, ext_tag_en = 0, take = 0;
    reg  [255:0] free = {256{1'b1}};
    wire         avail;
    wire [7:0]   tag;

    pcileech_req_tagalloc dut (.clk(clk), .rst(rst), .free(free), .ext_tag_en(ext_tag_en),
                               .take(take), .avail(avail), .tag(tag));

    always #5 clk = ~clk;
    integer errors = 0, checks = 0, i;

    task expect_offer;
        input [8*64-1:0] name; input want_avail; input [7:0] want_tag;
        begin
            #1;
            checks = checks + 1;
            if (avail !== want_avail || (want_avail && tag !== want_tag)) begin
                errors = errors + 1;
                $display("R1_TB_FAIL %0s: avail=%b tag=%0d want avail=%b tag=%0d",
                         name, avail, tag, want_avail, want_tag);
            end
        end
    endtask

    // Take the offered tag on the next edge; the table marks it non-FREE.
    task take_one;
        begin
            @(negedge clk); take = 1;
            @(posedge clk); #0 free[tag] = 1'b0;
            @(negedge clk); take = 0;
        end
    endtask

    task reset_all;
        input ext;
        begin
            @(negedge clk); rst = 1; ext_tag_en = ext; free = {256{1'b1}};
            @(negedge clk); rst = 0;
        end
    endtask

    initial begin
        reset_all(0);
        expect_offer("reset offers tag 0", 1, 8'd0);

        // round-robin: a just-freed tag is reused last, not first
        take_one; free[0] = 1'b1;
        expect_offer("after taking 0, offer 1 even though 0 is free", 1, 8'd1);
        take_one; take_one; take_one;                     // 1, 2, 3
        free[1] = 1'b1;
        expect_offer("freed 1 is not reused before 4", 1, 8'd4);

        // skip holes
        @(negedge clk); free[5] = 0; free[6] = 0;
        take_one;                                         // takes 4
        expect_offer("skip non-free 5 and 6", 1, 8'd7);

        // the pointer moves past the tag actually taken, not by one
        reset_all(0);
        @(negedge clk); free[9:0] = 10'h0;
        expect_offer("first free is 10", 1, 8'd10);
        take_one;
        @(negedge clk); free[5] = 1'b1;
        expect_offer("pointer is past 10, so freed 5 waits", 1, 8'd11);

        // 5-bit range: wrap at 31, never offer >= 32 while the enable is clear
        reset_all(0);
        for (i = 0; i < 30; i = i + 1) take_one;          // 0..29 taken
        @(negedge clk); free = {256{1'b1}}; free[29:0] = 30'h0; free[30] = 0; free[5] = 1;
        expect_offer("only 31 free at/after pointer 30", 1, 8'd31);
        take_one;
        expect_offer("pointer wraps to 0 in 5-bit range, finds 5", 1, 8'd5);
        @(negedge clk); free[31:0] = 32'h0;
        expect_offer("no tag in 0-31 while 32-255 are free", 0, 8'd0);

        // 8-bit range
        @(negedge clk); ext_tag_en = 1;
        expect_offer("extended range offers 32", 1, 8'd32);
        take_one;
        expect_offer("then 33", 1, 8'd33);

        // take with nothing available changes nothing
        reset_all(0);
        @(negedge clk); free[31:0] = 32'h0;
        take_one;
        @(negedge clk); free[31:0] = 32'hFFFF_FFFF;
        expect_offer("take while unavailable does not move pointer", 1, 8'd0);

        // clearing the enable with the pointer past 31 restarts the search in range
        reset_all(1);
        for (i = 0; i < 100; i = i + 1) take_one;         // pointer now 100
        @(negedge clk); free = {256{1'b1}}; ext_tag_en = 0;
        expect_offer("enable cleared with pointer 100: search restarts at 0", 1, 8'd0);
        // and tags >= 32 that are in use stay in use (the table owns them)
        @(negedge clk); ext_tag_en = 1; free[255:32] = {224{1'b0}}; free[31:0] = 32'h0;
        expect_offer("in-use high tags are not offered", 0, 8'd0);

        // wrap at 255 in the 8-bit range
        reset_all(1);
        for (i = 0; i < 255; i = i + 1) take_one;         // 0..254 taken, pointer 255
        @(negedge clk); free = {256{1'b1}}; free[254:3] = {252{1'b0}};
        expect_offer("offers 255 at pointer 255", 1, 8'd255);
        take_one;
        expect_offer("wraps to 0 after 255", 1, 8'd0);

        if (errors == 0) $display("R1_TB_PASS tb_req_tagalloc checks=%0d", checks);
        else             $display("R1_TB_FAILED tb_req_tagalloc errors=%0d checks=%0d", errors, checks);
        $finish;
    end
endmodule
