// Pull-stream scoreboard against the real allocator/classifier/table.
// Breaks caught: tag/header corruption, duplicate/lost beats, resource stalls,
// wrong refusal/accounting, packet disposition changes, stale reset data.
`timescale 1ns / 1ps
`include "pcileech_req_defs.svh"
`ifdef GATE_AXIS
/* verilator lint_off DECLFILENAME */
`include "pcileech_header.svh"
/* verilator lint_on DECLFILENAME */
`endif

module tb_req_gate;
    parameter integer CAP = 36;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg [15:0] live_rid = 16'h0218;
    reg bme = 1, ext_tag_en = 0;
    reg [2:0] mrrs_code = 0;
    reg [127:0] in_data = 0;
    reg [3:0] in_keep = 0;
    reg [8:0] in_user = 0;
    reg in_last = 0, in_valid = 0;
    wire in_ready;
    wire [127:0] out_data;
    wire [3:0] out_keep;
    wire [8:0] out_user;
    wire out_last, out_valid, out_has_data;
    reg out_ready = 0;
    wire adm_valid;
    wire [7:0] adm_tag, adm_host_tag;
    wire [12:0] adm_bc;
    wire [6:0] adm_la;
    wire [2:0] adm_tc;
    wire [1:0] adm_attr;
    wire [255:0] free;
    wire [8:0] n_reserved, n_issued, n_quarantined;
    wire [15:0] admitted_count;
    wire [111:0] refuse_counts;
    reg iss_valid = 0, rel_valid = 0, up_valid = 0, flr = 0;
    reg ctl_disable = 1;
    reg [7:0] iss_tag = 0, rel_tag = 0, up_tag = 0, lk_tag = 0;
    wire [1:0] lk_state;
    wire [7:0] lk_host_tag;
    wire [12:0] lk_remaining;
    wire [6:0] lk_next_la;
    wire [2:0] lk_tc;
    wire [1:0] lk_attr;
    wire err_bypass, err_release;

`ifdef GATE_AXIS
    IfAXIS128 axis_in();
    IfAXIS128 axis_out();
    assign axis_in.tdata = in_data;
    assign axis_in.tkeepdw = in_keep;
    assign axis_in.tuser = in_user;
    assign axis_in.tlast = in_last;
    assign axis_in.tvalid = in_valid;
    assign axis_in.has_data = source_index < send_limit;
    assign in_ready = axis_in.tready;
    assign out_data = axis_out.tdata;
    assign out_keep = axis_out.tkeepdw;
    assign out_user = axis_out.tuser;
    assign out_last = axis_out.tlast;
    assign out_valid = axis_out.tvalid;
    assign out_has_data = axis_out.has_data;
    assign axis_out.tready = out_ready;
    pcileech_req_gate_axis #(.N_NP_MAX(CAP)) dut (
        .tlps_in(axis_in), .tlps_out(axis_out),
`else
    pcileech_req_gate #(.N_NP_MAX(CAP)) dut (
        .in_data(in_data), .in_keep(in_keep), .in_user(in_user), .in_last(in_last),
        .in_valid(in_valid), .in_ready(in_ready),
        .out_data(out_data), .out_keep(out_keep), .out_user(out_user), .out_last(out_last),
        .out_valid(out_valid), .out_ready(out_ready), .out_has_data(out_has_data),
`endif
        .clk(clk), .rst(rst), .live_rid(live_rid), .bme(bme), .mrrs_code(mrrs_code),
        .ext_tag_en(ext_tag_en), .free(free), .n_reserved(n_reserved), .n_issued(n_issued),
        .adm_valid(adm_valid), .adm_tag(adm_tag), .adm_host_tag(adm_host_tag),
        .adm_bc(adm_bc), .adm_la(adm_la), .adm_tc(adm_tc), .adm_attr(adm_attr),
        .admitted_count(admitted_count), .refuse_counts(refuse_counts));

    pcileech_req_table tbl (
        .clk(clk), .rst(rst), .flr(flr), .ctl_code(4'd1), .ctl_disable(ctl_disable),
        .adm_valid(adm_valid), .adm_tag(adm_tag), .adm_host_tag(adm_host_tag),
        .adm_bc(adm_bc), .adm_la(adm_la), .adm_tc(adm_tc), .adm_attr(adm_attr),
        .iss_valid(iss_valid), .iss_tag(iss_tag), .rel_valid(rel_valid), .rel_tag(rel_tag),
        .lk_tag(lk_tag), .lk_state(lk_state), .lk_host_tag(lk_host_tag), .lk_superseded(),
        .lk_remaining(lk_remaining), .lk_next_la(lk_next_la), .lk_tc(lk_tc), .lk_attr(lk_attr),
        .up_valid(up_valid), .up_tag(up_tag), .up_retire(1'b1), .up_remaining(13'd0),
        .up_next_la(7'd0), .free(free), .to_valid(), .to_tag(), .n_reserved(n_reserved),
        .n_issued(n_issued), .n_quarantined(n_quarantined), .trn_pending(),
        .err_bypass(err_bypass), .err_release(err_release));

    reg [127:0] src_data[0:4095], exp_data[0:4095];
    reg [3:0] src_keep[0:4095], exp_keep[0:4095];
    reg [8:0] src_user[0:4095], exp_user[0:4095];
    reg src_last[0:4095], exp_last[0:4095];
    reg [7:0] exp_tags[0:1023], exp_hosts[0:1023];
    reg [12:0] exp_bc[0:1023];
    reg [6:0] exp_la[0:1023];
    reg [2:0] exp_tc[0:1023];
    reg [1:0] exp_attr[0:1023];
    integer offered = 0, source_index = 0, send_limit = 0;
    integer expected = 0, received = 0, expected_adm = 0, seen_adm = 0;
    integer checks = 0, cycle = 0, sink_mode = 0;
    reg source_gaps = 0, prev_ready = 0;

    task check(input ok, input [8*96-1:0] name);
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin
                $display("R1_TB_FAIL %0s cycle=%0d rx=%0d/%0d admits=%0d/%0d",
                         name, cycle, received, expected, seen_adm, expected_adm);
                $fatal(1);
            end
        end
    endtask

    // tready at this edge causes a registered beat, sampled by the gate at the
    // following edge. Valid is never gated by ready from the response cycle.
    always @(posedge clk) begin
        cycle <= cycle + 1;
        in_valid <= 0;
        if (!rst && in_ready && source_index < send_limit &&
            (!source_gaps || cycle % 7 != 3)) begin
            in_data <= src_data[source_index]; in_keep <= src_keep[source_index];
            in_user <= src_user[source_index]; in_last <= src_last[source_index];
            in_valid <= 1;
            source_index <= source_index + 1;
        end
    end
    always @(negedge clk) begin
        case (sink_mode)
            0: out_ready = !rst;
            1: out_ready = !rst && (cycle % 11 < 4);
            2: out_ready = 0;
            default: out_ready = !rst && (cycle % 17 == 0);
        endcase
    end
    always @(posedge clk) begin
        prev_ready <= !rst && out_ready;
        if (!rst) begin
            if (out_valid) begin
                check(prev_ready, "output must answer previous-cycle pull");
                check(received < expected, "no extra forwarded beat");
                check({out_data,out_keep,out_user,out_last} ===
                      {exp_data[received],exp_keep[received],exp_user[received],exp_last[received]},
                      "forwarded beat/keep/user/last equals independent scoreboard");
                received = received + 1;
            end
            if (adm_valid) begin
                check(seen_adm < expected_adm, "no unexpected admission on refusal/pass");
                check({adm_tag,adm_host_tag,adm_bc,adm_la,adm_tc,adm_attr} ===
                      {exp_tags[seen_adm],exp_hosts[seen_adm],exp_bc[seen_adm],
                       exp_la[seen_adm],exp_tc[seen_adm],exp_attr[seen_adm]},
                      "admission metadata and allocated tag");
                check(free[adm_tag], "admit only a FREE tag");
                seen_adm = seen_adm + 1;
            end
            check(!err_release && !err_bypass, "refusals do not release/issue table entries");
        end
    end

    function automatic [127:0] mrd(input [7:0] host_tag);
        // 3DW, length 1, RID 0218, FirstBE=1001 => span 4, LA=0x40,
        // TC=5, Attr=3. Upper DW is preserved even though keep=7.
        mrd = {32'h87654321,32'h00001040,16'h0218,host_tag,8'h09,32'h00503001};
    endfunction
    task add(input [127:0] d, input [3:0] keep, input first, input last,
             input pass, input track, input [7:0] tag);
        reg [127:0] want;
        begin
            src_data[offered] = d; src_keep[offered] = keep;
            src_user[offered] = {7'b1010010,last,first}; src_last[offered] = last;
            offered = offered + 1;
            if (pass) begin
                want = d;
                if (track) want[47:40] = tag;
                exp_data[expected] = want; exp_keep[expected] = keep;
                exp_user[expected] = {7'b1010010,last,first}; exp_last[expected] = last;
                expected = expected + 1;
            end
            if (track) begin
                exp_tags[expected_adm] = tag; exp_hosts[expected_adm] = d[47:40];
                exp_bc[expected_adm] = 13'd4; exp_la[expected_adm] = 7'h40;
                exp_tc[expected_adm] = 3'd5; exp_attr[expected_adm] = 2'd3;
                expected_adm = expected_adm + 1;
            end
        end
    endtask
    task start_send;
        begin @(negedge clk); send_limit = offered; end
    endtask
    task drain;
        integer deadline;
        begin
            start_send;
            deadline = cycle + 30000;
            while ((source_index != send_limit || received != expected || in_valid) && cycle < deadline)
                @(negedge clk);
            repeat (8) @(negedge clk);
            check(source_index == send_limit && received == expected, "stream drains without deadlock");
            check(seen_adm == expected_adm, "all expected admissions occurred");
            check(!out_has_data, "has_data clears after all buffered beats sent");
        end
    endtask
    task reset_all;
        begin
            @(negedge clk); rst = 1; sink_mode = 0; send_limit = source_index;
            repeat (3) @(negedge clk);
            check(!adm_valid && !out_valid && !in_ready && !out_has_data,
                  "reset masks stream and admission");
            offered = 0; source_index = 0; send_limit = 0; expected = 0; received = 0;
            expected_adm = 0; seen_adm = 0; bme = 1; ext_tag_en = 0; source_gaps = 0;
            live_rid = 16'h0218; mrrs_code = 0;
            ctl_disable = 1;
            rst = 0;
            @(negedge clk);
            check(admitted_count == 0 && refuse_counts == 0, "session reset clears counters");
        end
    endtask
    task pulse_release(input [7:0] tag);
        begin
            @(negedge clk); rel_tag = tag; rel_valid = 1;
            @(negedge clk); rel_valid = 0;
        end
    endtask
    task pulse_issue(input [7:0] tag);
        begin
            @(negedge clk); iss_tag = tag; iss_valid = 1;
            @(negedge clk); iss_valid = 0;
        end
    endtask
    task pulse_retire(input [7:0] tag);
        begin
            @(negedge clk); up_tag = tag; up_valid = 1;
            @(negedge clk); up_valid = 0;
        end
    endtask
    task refused(input [127:0] d, input first, input last, input integer reason);
        reg [111:0] before_counts, want_counts;
        integer before_adm;
        begin
            before_counts = refuse_counts; before_adm = seen_adm;
            want_counts = before_counts;
            want_counts[(reason-1)*16 +: 16] = before_counts[(reason-1)*16 +: 16] + 16'd1;
            add(d,4'hf,first,last,0,0,0);
            if (!last) begin
                // Looks like a valid first MRd: must still drop until actual tlast.
                add(mrd(8'hff),4'h7,1,0,0,0,0);
                add(mrd(8'hff),4'h7,0,1,0,0,0);
            end
            // A posted packet immediately behind a refusal must make progress.
            add(128'h11223344_aabbccdd_02030405_40000001,4'hf,1,1,1,0,0);
            drain;
            check(refuse_counts === want_counts, "one matching refusal counter per packet");
            check(seen_adm == before_adm, "refusal never reserves an entry");
        end
    endtask

    integer i, limit;
    reg [127:0] d;
    initial begin
        reset_all;
        // PASS multi-beat write, all completion forms, and posted messages.
        sink_mode = 1; source_gaps = 1;
        add(128'h01020304_05060708_090a0b0c_40000008,15,1,0,1,0,0);
        add(128'hffffffff_eeeeeeee_dddddddd_cccccccc,15,0,0,1,0,0);
        add(128'h01234567_89abcdef_02468ace_13579bdf,3,0,1,1,0,0);
        add(128'h01234567_89abcdef_02468ace_4a000008,15,1,0,1,0,0);
        add(128'h89abcdef_01234567_aaaaaaaa_bbbbbbbb,1,0,1,1,0,0);
        add(128'h11111111_22222222_33333333_0a000000,7,1,1,1,0,0);
        add(128'h44444444_55555555_66666666_0b000000,7,1,1,1,0,0);
        add(128'h77777777_88888888_99999999_30000000,15,1,1,1,0,0);
        drain;
        check(admitted_count == 0 && refuse_counts == 0 && n_reserved == 0,
              "PASS traffic remains completely untracked");

        // MRd32 then MRd64. Both alter only tag, including unused upper DWs.
        add(mrd(8'ha0),7,1,1,1,1,0);
        d = mrd(8'hb1); d[31:29] = 3'b001;
        d[95:64] = 32'h00000001; d[127:96] = 32'h00001040;
        add(d,15,1,1,1,1,1);
        drain;
        lk_tag = 0; #1;
        check({lk_state,lk_host_tag,lk_remaining,lk_next_la,lk_tc,lk_attr} ===
              {`REQ_ST_RESERVED,8'ha0,13'd4,7'h40,3'd5,2'd3}, "real table stores gate metadata");
        check(admitted_count == 2 && n_reserved == 2, "tracked reads reserve exactly once");

        // All refusal reasons, plus check priority and multi-beat discard.
        d = mrd(1); d[28:24] = 5'b00001; refused(d,1,0,1);
        refused(mrd(2),1,0,2);
        d = mrd(3); d[15] = 1; refused(d,1,1,3);
        d = mrd(4); d[63:48] = 16'h1802; refused(d,1,1,4);
        bme = 0; refused(mrd(5),1,1,5); bme = 1;
        d = mrd(6); d[9:0] = 10'd64; d[39:32] = 8'hff; refused(d,1,1,2);
        refused(mrd(7),0,1,2); // orphan continuation

        // Controls are sampled on input arrival, not delayed until output pull.
        reset_all; sink_mode = 2;
        add(mrd(8'hc2),7,1,1,1,1,0); start_send;
        wait(seen_adm == 1); @(negedge clk);
        bme = 0; live_rid = 16'h1234; mrrs_code = 5;
        repeat(8) @(negedge clk);
        check(received == 0 && n_reserved == 1 && out_has_data, "admitted beat retained under stall");
        sink_mode = 0; drain;

        // Fill either the base-tag range or the configured cap, then prove
        // refusal instead of indefinite stalling; posted traffic still drains.
        reset_all; sink_mode = 1;
        limit = (CAP < 32) ? CAP : 32;
        for(i=0;i<limit;i=i+1) add(mrd(8'(i)),7,1,1,1,1,8'(i));
        drain;
        if (CAP >= 32) refused(mrd(8'hf0),1,1,6);
        else refused(mrd(8'hf0),1,1,7);
        pulse_issue(0);
        check(n_issued == 1 && n_reserved == 9'(limit-1), "issue changes count class only");
        // Retire tag 0: round-robin must prefer the next unused tag, except
        // when all 32 base tags were full and 0 is the only eligible free tag.
        pulse_retire(0);
        add(mrd(8'hf1),7,1,1,1,1,(limit == 32) ? 8'd0 : 8'(limit)); drain;
        ext_tag_en = 1;
        if (CAP > 32) begin
            for(i=32;i<CAP;i=i+1) add(mrd(8'(i)),7,1,1,1,1,8'(i));
            drain;
        end
        refused(mrd(8'hf2),1,1,(CAP == 256) ? 6 : 7);
        pulse_issue(8'(CAP-1));
        refused(mrd(8'hf4),1,1,(CAP == 256) ? 6 : 7);
        pulse_release((limit == 32) ? 8'd0 : 8'(limit));
        add(mrd(8'hf3),7,1,1,1,1,(CAP == 256) ? 8'd0 :
            (CAP < 32) ? 8'(CAP+1) : 8'(CAP)); drain;
        check({1'b0,n_reserved} + {1'b0,n_issued} == 10'(CAP), "in-flight count never exceeds NP cap");

        // QUARANTINED is not in the NP count, but its tags remain unavailable.
        reset_all; ext_tag_en = 1;
        for(i=0;i<CAP;i=i+1) add(mrd(8'(i)),7,1,1,1,1,8'(i));
        drain;
        for(i=0;i<CAP;i=i+1) pulse_issue(8'(i));
        @(negedge clk); flr = 1; @(negedge clk); flr = 0;
        check(n_issued == 0 && n_quarantined == 9'(CAP), "FLR quarantines issued entries");
        if(CAP < 256) begin add(mrd(8'hde),7,1,1,1,1,8'(CAP)); drain; end
        else refused(mrd(8'hde),1,1,6);

        // Reuse a released low tag last, and honor a live Extended Tag clear.
        reset_all; ext_tag_en = 1;
        for(i=0;i<3;i=i+1) add(mrd(8'(i)),7,1,1,1,1,8'(i));
        drain; pulse_release(0); pulse_release(1);
        add(mrd(8'hd0),7,1,1,1,1,3); drain;
        pulse_release(2); pulse_release(3);
        ext_tag_en = 0;
        add(mrd(8'hd1),7,1,1,1,1,4); drain;

        // With real timeout/drain transitions, admission resumes without a
        // session reset. The next allocation still respects round-robin.
        reset_all; ctl_disable=0;
        limit=(CAP < 32) ? CAP : 32;
        for(i=0;i<limit;i=i+1) add(mrd(8'(i)),7,1,1,1,1,8'(i));
        drain;
        for(i=0;i<limit;i=i+1) pulse_issue(8'(i));
        wait(n_quarantined==9'(limit));
        if(CAP >= 32) refused(mrd(8'hf5),1,1,6);
        wait(n_quarantined==0);
        add(mrd(8'hd2),7,1,1,1,1,(limit==32) ? 8'd0 : 8'(limit)); drain;

        // Many back-to-back PASS beats interspersed with read refusals. Abrupt
        // stalls happen while a response to an earlier pull is still in flight.
        reset_all; sink_mode = 3; source_gaps = 1;
        for(i=0;i<600;i=i+1) begin
            d = {32'(i),32'h10203040,32'h50607080,32'h40000001};
            add(d,15,1,1,1,0,0);
            if(i%9==0) begin d[28:24]=5'd2; add(d,15,1,1,0,0,0); end
        end
        drain;
        check(refuse_counts[15:0] == 67 && admitted_count == 0,
              "backpressure campaign counts every discarded packet");

        // Reset discards queued data and mid-packet state. Orphan tail after
        // reset is dropped, and a subsequent new packet passes normally.
        reset_all; sink_mode = 2;
        add(128'h12345678_12345678_12345678_40000008,15,1,0,1,0,0);
        start_send; wait(source_index==send_limit); repeat(5) @(negedge clk);
        reset_all;
        d=mrd(8'hfe); d[31:29]=3'b010;
        refused(d,0,0,2); // orphan posted tail must not bypass reset recovery
        add(mrd(8'hdf),7,1,1,1,1,0); drain;
        check(admitted_count == 1 && n_reserved == 1, "post-reset session starts at tag zero");
        $display("R1_TB_PASS tb_req_gate checks=%0d CAP=%0d",checks,CAP);
        $finish;
    end
    initial begin #10000000; $display("R1_TB_FAIL timeout"); $fatal(1); end
endmodule
