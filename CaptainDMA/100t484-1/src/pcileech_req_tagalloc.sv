//
// PCILeech FPGA.
//
// R1 requester tracking: round-robin internal-tag allocator.
// Contract: PCILeechFWGenerator docs/development/MSIX_REQUESTER_CONTRACT.md section 5.
//
// Offers the first FREE tag at or after a pointer, wrapping within the live tag range
// (0-31, or 0-255 with Extended Tag Field Enable). The pointer moves past each tag
// taken, so a just-released tag is the last to be reused, which maximises separation
// from any straggling completion. The range is re-read every cycle from the enable
// registered in pcileech_pcie_a7. Clearing the enable only restricts new offers,
// and it never frees tags already in use.
//
// The offer is registered (timing F1): each cycle computes the next offer for both
// outcomes from the current free vector — A from the unchanged pointer if nothing is
// taken, B from just past the current offer with that tag excluded if it is taken —
// and take only selects between them. A tag freed in cycle n is offerable from n+2
// instead of n+1. An offered tag is FREE when taken: only admission (take) removes a
// tag from FREE, and B excludes the tag just taken. The range is applied again at
// use, so clearing the enable withdraws an out-of-range offer immediately.
//
`timescale 1ns / 1ps

module pcileech_req_tagalloc (
    input           clk,
    input           rst,
    input  [255:0]  free,           // 1 = entry FREE, indexed by internal tag
    input           ext_tag_en,     // cfg_dcommand[8]: range 0-255, else 0-31
    input           take,           // consume the offered tag this cycle
    output          avail,
    output [7:0]    tag
);
    reg  [7:0]   ptr;
    reg  [7:0]   offer;
    reg          offer_ok;

    wire [255:0] in_range = ext_tag_en ? {256{1'b1}} : {224'h0, 32'hFFFF_FFFF};
    wire [255:0] cand     = free & in_range;

    // Round-robin pick: first candidate at or after start, else the lowest. Each mask
    // bit compares only the 8-bit start, avoiding a 256-bit shifted carry chain.
    // A (keep): candidates from ptr. B (take): candidates from offer+1 without offer.
    wire [7:0]   start_take = offer + 8'd1;
    wire [255:0] cand_take;
    wire [255:0] after_keep, after_take;
    genvar index;
    generate for (index = 0; index < 256; index = index + 1) begin : g_pointer_mask
        assign cand_take[index]  = cand[index] & (8'(index) != offer);
        // At index 255 this is constant for binary starts; kept for X propagation.
        /* verilator lint_off CMPCONST */
        assign after_keep[index] = cand[index]      & (8'(index) >= ptr);
        assign after_take[index] = cand_take[index] & (8'(index) >= start_take);
        /* verilator lint_on CMPCONST */
    end endgenerate

    function automatic [8:0] lowest(input [255:0] v);   // {found, index}
        integer k;
        begin
            lowest = 9'd0;
            for (k = 255; k >= 0; k = k - 1)
                if (v[k]) lowest = {1'b1, k[7:0]};
        end
    endfunction

    wire [8:0] hi_keep = lowest(after_keep);
    wire [8:0] lo_keep = lowest(cand);
    wire [8:0] hi_take = lowest(after_take);
    wire [8:0] lo_take = lowest(cand_take);
    wire [8:0] next_keep = hi_keep[8] ? hi_keep : lo_keep;
    wire [8:0] next_take = hi_take[8] ? hi_take : lo_take;

    assign avail = offer_ok && (ext_tag_en || offer < 8'd32);
    assign tag   = offer;

    // The pointer moves past the tag taken (8-bit wrap at 255).
    always @(posedge clk)
        if (rst) begin
            ptr <= 8'd0; offer <= 8'd0; offer_ok <= 1'b0;
        end else if (take && avail) begin
            ptr <= offer + 8'd1;
            {offer_ok, offer} <= next_take;
        end else
            {offer_ok, offer} <= next_keep;
endmodule
