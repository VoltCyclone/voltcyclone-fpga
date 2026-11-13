//
// PCILeech FPGA.
//
// R1 requester tracking: round-robin internal-tag allocator.
// Contract: PCILeechFWGenerator docs/development/MSIX_REQUESTER_CONTRACT.md section 5.
//
// Offers the first FREE tag at or after a pointer, wrapping within the live tag range
// (0-31, or 0-255 with Extended Tag Field Enable). The pointer moves past each tag
// taken, so a just-released tag is the last to be reused, which maximises separation
// from any straggling completion. The range is re-read every cycle: clearing the
// enable only restricts new offers, it never frees tags already in use.
//
`timescale 1ns / 1ps

module req_tagalloc_reference (
    input           clk,
    input           rst,
    input  [255:0]  free,           // 1 = entry FREE, indexed by internal tag
    input           ext_tag_en,     // cfg_dcommand[8]: range 0-255, else 0-31
    input           take,           // consume the offered tag this cycle
    output          avail,
    output [7:0]    tag
);
    reg  [7:0]   ptr;

    wire [255:0] in_range = ext_tag_en ? {256{1'b1}} : {224'h0, 32'hFFFF_FFFF};
    wire [255:0] cand     = free & in_range;
    wire [255:0] at_or_after = cand & ~((256'd1 << ptr) - 256'd1);

    function automatic [8:0] lowest(input [255:0] v);   // {found, index}
        integer k;
        begin
            lowest = 9'd0;
            for (k = 255; k >= 0; k = k - 1)
                if (v[k]) lowest = {1'b1, k[7:0]};
        end
    endfunction

    wire [8:0] hi = lowest(at_or_after);
    wire [8:0] lo = lowest(cand);

    // Nothing free at or after the pointer wraps to the lowest free tag in range. This
    // also covers a pointer beyond the range (past 31, or after the enable is cleared).
    assign avail = lo[8];
    assign tag   = hi[8] ? hi[7:0] : lo[7:0];

    // Move past the tag taken (8-bit wrap at 255).
    always @(posedge clk)
        if (rst)                 ptr <= 8'd0;
        else if (take && avail)  ptr <= tag + 8'd1;
endmodule
