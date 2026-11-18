// Counter boundary test: wrapping any saturating counter must fail.
// Table lifecycle is covered by tb_req_gate. Here capacity is kept available
// across tag rotation to isolate the counters from lifecycle/timer behavior.
`timescale 1ns / 1ps
module tb_req_gate_counters;
    reg clk=0, rst=1;
    always #5 clk=~clk;
    reg [127:0] hdr=0;
    reg bme=1;
    reg [255:0] free={256{1'b1}};
    reg [8:0] n_reserved=0, n_issued=0;
    reg valid=0;
    wire ready, out_valid, adm_valid;
    wire [15:0] admitted_count;
    wire [111:0] refuse_counts;
    integer left=0, received=0, admitted=0, checks=0;
    pcileech_req_gate dut (.np_cap(9'd3),
        .clk(clk),.rst(rst),.live_rid(16'h0218),.bme(bme),.mrrs_code(3'd0),
        .ext_tag_en(1'b1),.free(free),.n_reserved(n_reserved),.n_issued(n_issued),
        .in_data(hdr),.in_keep(4'h7),.in_user(9'd3),.in_last(1'b1),
        .in_valid(valid),.in_ready(ready),.out_data(),.out_keep(),.out_user(),
        .out_last(),.out_valid(out_valid),.out_ready(1'b1),.out_has_data(),
        .adm_valid(adm_valid),.adm_tag(),.adm_host_tag(),.adm_bc(),.adm_la(),.adm_tc(),.adm_attr(),
        .admitted_count(admitted_count),.refuse_counts(refuse_counts));
    always @(posedge clk) begin
        valid <= !rst && ready && left>0;
        if (!rst && ready && left>0) left <= left-1;
        if(!rst && out_valid) received=received+1;
        if(!rst && adm_valid) admitted=admitted+1;
    end
    task check(input ok, input [8*80-1:0] name);
        begin
            checks=checks+1;
            if(ok !== 1'b1) begin $display("R1_TB_FAIL %0s",name); $fatal(1); end
        end
    endtask
    task send_many(input [127:0] data);
        begin
            @(negedge clk); hdr=data; left=65540;
            wait(left==0); repeat(10) @(negedge clk);
        end
    endtask
    reg [127:0] read_hdr, bad;
    reg [111:0] want_counts=0;
    integer reason;
    initial begin
        repeat(3) @(negedge clk); rst=0;
        read_hdr=128'h0_00001040_0218ac09_00000001;
        send_many(read_hdr);
        check(admitted_count==16'hffff && admitted==65540 && received==65540,
              "admitted counter saturates while forwarding continues");
        check(refuse_counts==0,"admissions do not increment refusal counters");
        for(reason=1;reason<=7;reason=reason+1) begin
            bad=read_hdr;
            case(reason)
                1: bad[28:24]=5'd1;
                2: begin bad[9:0]=10'd64; bad[39:32]=8'hff; end
                3: bad[15]=1;
                4: bad[63:48]=16'h1802;
                5: bme=0;
                6: free=0;
                7: begin n_reserved=2; n_issued=1; end
                default: $fatal(1,"invalid test reason");
            endcase
            send_many(bad);
            want_counts[(reason-1)*16 +: 16]=16'hffff;
            check(refuse_counts===want_counts,"each refusal counter saturates without affecting others");
            check(admitted==65540 && received==65540,"saturated refusal still discards without admitting");
            bme=1; free={256{1'b1}}; n_reserved=0; n_issued=0;
        end
        @(negedge clk); rst=1; repeat(2) @(negedge clk);
        check(admitted_count==0 && refuse_counts==0,"session reset clears saturated counters");
        $display("R1_TB_PASS tb_req_gate_counters checks=%0d",checks); $finish;
    end
    initial begin #20000000; $display("R1_TB_FAIL counter timeout"); $fatal(1); end
endmodule
