// Four-state equivalence against the frozen pre-optimization allocator.
`timescale 1ns / 1ps
module tb_req_tagalloc_equiv;
    reg clk=0, rst=0, take=0, ext_tag_en=0;
    reg [255:0] free=0;
    reg [7:0] ptr_drive=0;
    wire gold_avail, gate_avail;
    wire [7:0] gold_tag, gate_tag;
    integer checks=0, p, mode, n, bit_index;
    integer seed=32'h13579bdf;
    pcileech_req_tagalloc gate(.clk(clk),.rst(rst),.free(free),
        .ext_tag_en(ext_tag_en),.take(take),.avail(gate_avail),.tag(gate_tag));
    req_tagalloc_reference gold(.clk(clk),.rst(rst),.free(free),
        .ext_tag_en(ext_tag_en),.take(take),.avail(gold_avail),.tag(gold_tag));
    initial begin #1000000; $fatal(1,"R1_TB_FAIL equivalence watchdog"); end
    task automatic compare;
        #1;
        checks=checks+1;
        if ({gate_avail,gate_tag} !== {gold_avail,gold_tag})
            $fatal(1,"R1_TB_FAIL equivalent offer ptr=%b ext=%b gold=%b/%h gate=%b/%h",
                ptr_drive,ext_tag_en,gold_avail,gold_tag,gate_avail,gate_tag);
    endtask
    task automatic random_free;
        free={$random(seed),$random(seed),$random(seed),$random(seed),
              $random(seed),$random(seed),$random(seed),$random(seed)};
    endtask
    initial begin
        force gate.ptr=ptr_drive;
        force gold.ptr=ptr_drive;
        for(mode=0;mode<2;mode=mode+1) begin
            ext_tag_en=1'(mode);
            for(p=0;p<256;p=p+1) begin
                ptr_drive=8'(p);
                free=0; compare;
                free={256{1'b1}}; compare;
                free=256'd1 << p; compare;
                free=256'd1 << ((p+17)&255); compare;
                free={128{2'b10}}; compare;
                for(n=0;n<8;n=n+1) begin random_free; compare; end
                random_free; free[p]=1'bx; compare;
                free[p]=1'bz; compare;
            end
        end
        for(mode=0;mode<4;mode=mode+1) begin
            case(mode)
                0: ext_tag_en=0;
                1: ext_tag_en=1;
                2: ext_tag_en=1'bx;
                default: ext_tag_en=1'bz;
            endcase
            ptr_drive=8'bxxxxxxxx; free={256{1'b1}}; compare;
            ptr_drive=8'bzzzzzzzz; free={256{1'b1}}; compare;
            for(p=0;p<256;p=p+17) begin
                for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                    ptr_drive=8'(p); ptr_drive[bit_index]=1'bx;
                    random_free; compare;
                    ptr_drive[bit_index]=1'bz; compare;
                end
            end
        end
        $display("R1_TB_PASS tb_req_tagalloc_equiv checks=%0d",checks);
        $finish;
    end
endmodule
