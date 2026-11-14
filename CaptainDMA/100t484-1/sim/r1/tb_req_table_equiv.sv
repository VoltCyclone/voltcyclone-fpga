`timescale 1ns/1ps
`include "pcileech_req_defs.svh"
// Lockstep equivalence: req_table_reference.sv (4e2950b) vs the current table
// (XOR live-value table, sweep decisions from registered state). Legal random
// admit/issue/release/progress/retire traffic, FLR, short completion timeout
// (code 1) and retires aimed at the entry the sweep expires or drains.
module tb_req_table_equiv;
  reg clk=0, rst=1, flr=0; reg [3:0] code=4'd1; integer coll=0; always #5 clk=~clk;
  reg adm_valid=0, iss_valid=0, rel_valid=0, up_valid=0, up_retire=0;
  reg [7:0] adm_tag, adm_host_tag, iss_tag, rel_tag, up_tag, lk_tag;
  reg [12:0] adm_bc, up_remaining; reg [6:0] adm_la, up_next_la; reg [2:0] adm_tc; reg [1:0] adm_attr;
  wire [1:0] s_a, s_b; wire [7:0] h_a, h_b; wire sp_a, sp_b; wire [12:0] r_a, r_b; wire [6:0] l_a, l_b;
  wire [2:0] t_a, t_b; wire [1:0] at_a, at_b; wire [255:0] f_a, f_b;
  wire tv_a, tv_b; wire [7:0] tt_a, tt_b; wire [8:0] nr_a,nr_b,ni_a,ni_b,nq_a,nq_b; wire tp_a,tp_b,eb_a,eb_b,er_a,er_b;
`define PORTS(SUF) .clk(clk),.rst(rst),.flr(flr),.ctl_code(code),.ctl_disable(1'b0), \
  .adm_valid(adm_valid),.adm_tag(adm_tag),.adm_host_tag(adm_host_tag),.adm_bc(adm_bc),.adm_la(adm_la),.adm_tc(adm_tc),.adm_attr(adm_attr), \
  .iss_valid(iss_valid),.iss_tag(iss_tag),.rel_valid(rel_valid),.rel_tag(rel_tag),.lk_tag(lk_tag), \
  .lk_state(s_``SUF),.lk_host_tag(h_``SUF),.lk_superseded(sp_``SUF),.lk_remaining(r_``SUF),.lk_next_la(l_``SUF),.lk_tc(t_``SUF),.lk_attr(at_``SUF), \
  .up_valid(up_valid),.up_tag(up_tag),.up_retire(up_retire),.up_remaining(up_remaining),.up_next_la(up_next_la), \
  .free(f_``SUF),.to_valid(tv_``SUF),.to_tag(tt_``SUF),.n_reserved(nr_``SUF),.n_issued(ni_``SUF),.n_quarantined(nq_``SUF), \
  .trn_pending(tp_``SUF),.err_bypass(eb_``SUF),.err_release(er_``SUF)
  pcileech_req_table_ref A(`PORTS(a));
  pcileech_req_table     B(`PORTS(b));
  integer n, cmp=0, live=0, lvt1=0, k, tos=0; always @(posedge clk) if (tv_a) tos++;
  function automatic [7:0] pick(input [1:0] want);   // random tag in a state, else 8'hff marker
    integer j, o; pick=8'hff; o=$urandom;
    for (j=0;j<256;j++) if (A.st[(j+o)&255]==want) begin pick=(j+o)&255; return pick; end
  endfunction
  initial begin
    adm_tag=0; adm_host_tag=0; iss_tag=0; rel_tag=0; up_tag=0; lk_tag=0; adm_bc=0; up_remaining=0; adm_la=0; up_next_la=0; adm_tc=0; adm_attr=0;
    repeat(3) @(posedge clk); rst=0;
    for (n=0;n<400000;n++) begin
      @(negedge clk);
      adm_valid=0; iss_valid=0; rel_valid=0; up_valid=0; up_retire=0; flr=($urandom%5000)==0;
      if ($urandom%3==0) begin adm_tag=pick(`REQ_ST_FREE); if(adm_tag!=8'hff) begin adm_valid=1; adm_host_tag=$urandom; adm_bc=$urandom; adm_la=$urandom; adm_tc=$urandom; adm_attr=$urandom; end end
      if ($urandom%3==0) begin iss_tag=pick(`REQ_ST_RESERVED); if(iss_tag!=8'hff && !(adm_valid&&adm_tag==iss_tag)) iss_valid=1; end
      if ($urandom%11==0) begin rel_tag=pick(`REQ_ST_RESERVED); if(rel_tag!=8'hff && !(iss_valid&&iss_tag==rel_tag)) rel_valid=1; end
      if ($urandom%6==0) begin up_tag=pick($urandom%2 ? `REQ_ST_ISSUED : `REQ_ST_QUARANTINED); if(up_tag!=8'hff) begin up_valid=1; up_retire=($urandom%4==0); up_remaining=$urandom; up_next_la=$urandom; end end
      // Bias toward retiring the entry the sweep is visiting this cycle.
      #0.1;
      if ((B.sw_expire_raw || B.sw_drain_raw) ? ($urandom%2==0) : ($urandom%64==0 && (A.st[A.sw_idx]==`REQ_ST_ISSUED || A.st[A.sw_idx]==`REQ_ST_QUARANTINED))) begin
        up_tag=A.sw_idx; up_valid=1; up_retire=1; up_remaining=0; up_next_la=$urandom;
      end
      lk_tag = ($urandom%2 && up_valid) ? up_tag : $urandom;
      #0.8;
      if (up_valid && up_retire && up_tag==A.sw_idx && (B.sw_expire_raw || B.sw_drain_raw)) coll++;
      if (A.st[lk_tag]!=`REQ_ST_FREE) begin
        live++; if (B.ga[lk_tag]^B.gu[lk_tag]) lvt1++;
        if ({s_a,h_a,sp_a,r_a,l_a,t_a,at_a} !== {s_b,h_b,sp_b,r_b,l_b,t_b,at_b}) begin
          $display("R1_TB_FAIL lookup mismatch n=%0d tag=%0d ref=%h new=%h", n, lk_tag, {s_a,h_a,sp_a,r_a,l_a,t_a,at_a}, {s_b,h_b,sp_b,r_b,l_b,t_b,at_b}); $fatal(1);
        end
        cmp++;
      end
      if ({f_a,tv_a,tt_a,nr_a,ni_a,nq_a,tp_a,eb_a,er_a} !== {f_b,tv_b,tt_b,nr_b,ni_b,nq_b,tp_b,eb_b,er_b}) begin $display("R1_TB_FAIL status mismatch n=%0d",n); $fatal(1); end
      for (k=0;k<256;k++) if (A.st[k]!=`REQ_ST_FREE && A.lvt[k]!==(B.ga[k]^B.gu[k])) begin $display("R1_TB_FAIL live-value mismatch n=%0d tag=%0d",n,k); $fatal(1); end
    end
    $display("R1_TB_PASS tb_req_table_equiv cycles=%0d live_lookups=%0d update_bank_lookups=%0d timeouts_seen=%0d swept_retires=%0d", n, live, lvt1, tos, coll); $finish;
  end
endmodule
