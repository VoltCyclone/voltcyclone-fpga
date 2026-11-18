// Executable specification for pcileech_req_tagalloc (registered offer). Written
// for clarity, not timing: a plain modular scan from the start index. Same ports and
// register names as the RTL so Yosys can match state for sequential equivalence.
//   next offer if nothing is taken: first candidate scanning up from ptr (wrapping)
//   next offer if the offer is taken: first candidate scanning up from offer+1,
//     excluding the offer itself; the pointer moves to offer+1
//   candidates: free & range (0-31 unless ext_tag_en); avail re-applies the range.
module req_tagalloc_spec (
    input           clk,
    input           rst,
    input  [255:0]  free,
    input           ext_tag_en,
    input           take,
    output          avail,
    output [7:0]    tag
);
    reg  [7:0] ptr;
    reg  [7:0] offer;
    reg        offer_ok;

    function automatic [8:0] scan(input [255:0] v, input [7:0] start, input en);
        integer d;
        reg [7:0] idx;
        begin
            scan = 9'd0;
            for (d = 255; d >= 0; d = d - 1) begin
                idx = start + d[7:0];
                if (v[idx] && (en || idx < 8'd32)) scan = {1'b1, idx};
            end
        end
    endfunction

    wire [255:0] masked = free & ~(256'd1 << offer);
    assign avail = offer_ok && (ext_tag_en || offer < 8'd32);
    assign tag   = offer;

    always @(posedge clk)
        if (rst) begin
            ptr <= 8'd0; offer <= 8'd0; offer_ok <= 1'b0;
        end else if (take && avail) begin
            ptr <= offer + 8'd1;
            {offer_ok, offer} <= scan(masked, offer + 8'd1, ext_tag_en);
        end else
            {offer_ok, offer} <= scan(free, ptr, ext_tag_en);
endmodule
