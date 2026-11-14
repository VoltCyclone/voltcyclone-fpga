// k-induction harness: an offered tag is FREE whenever it is taken.
// Environment assumption (from pcileech_req_table): a tag leaves FREE only when the
// allocator's offer is taken (reset sets every entry FREE); any tag may become FREE.
module tagalloc_safety (
    input           clk,
    input           rst,
    input  [255:0]  free,
    input           ext_tag_en,
    input           take_req
);
    wire        avail;
    wire [7:0]  tag;
    wire        take = take_req && avail && !rst;   // the gate admits only with a tag
    pcileech_req_tagalloc dut (.clk(clk), .rst(rst), .free(free), .ext_tag_en(ext_tag_en),
                               .take(take), .avail(avail), .tag(tag));

    reg         v = 1'b0;
    reg         rst_p, take_p;
    reg [7:0]   tag_p;
    reg [255:0] free_p;
    always @(posedge clk) begin
        v <= 1'b1; rst_p <= rst; take_p <= take; tag_p <= tag; free_p <= free;
    end
    wire [255:0] taken_p = take_p ? (256'd1 << tag_p) : 256'd0;

    always @* begin
        if (v)
            assume((free_p & ~free & ~taken_p) == 256'd0);
        if (!v) assume(rst);
        // Port-level only (no hierarchical references). Any visible offer is FREE:
        // each new offer is drawn from the current free vector, the taken tag is
        // excluded, and only taking removes a tag from FREE.
        if (v && !rst_p && avail)
            assert(free[tag]);
        if (take)
            assert(free[tag]);
    end
endmodule
