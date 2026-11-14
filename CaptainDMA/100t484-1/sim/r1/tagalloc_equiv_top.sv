module equiv_top (input clk, input rst, input [255:0] free, input ext_tag_en, input take);
    wire trigger;
    wire       gold_avail, gate_avail, gold_offer_ok, gate_offer_ok;
    wire [7:0] gold_tag, gate_tag, gold_offer, gate_offer, gold_ptr, gate_ptr;
    miter m (.in_clk(clk), .in_rst(rst), .in_free(free), .in_ext_tag_en(ext_tag_en),
             .in_take(take), .trigger(trigger),
             .gold_avail(gold_avail), .gate_avail(gate_avail),
             .gold_tag(gold_tag), .gate_tag(gate_tag),
             .gold_offer(gold_offer), .gate_offer(gate_offer),
             .gold_offer_ok(gold_offer_ok), .gate_offer_ok(gate_offer_ok),
             .gold_ptr(gold_ptr), .gate_ptr(gate_ptr));
    reg v = 1'b0;
    always @(posedge clk) v <= 1'b1;
    always @* begin
        if (!v) assume(rst);
        if (v) begin
            assert(gold_ptr == gate_ptr);
            assert(gold_offer_ok == gate_offer_ok);
            assert(gold_offer == gate_offer);
            assert(gold_avail == gate_avail);
            assert(gold_tag == gate_tag);
        end
    end
endmodule
