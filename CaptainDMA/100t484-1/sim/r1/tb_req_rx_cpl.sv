`timescale 1ns / 1ps
`include "pcileech_req_defs.svh"

module tb_req_rx_cpl;
    reg clk = 0, rst = 1, flr = 0;
    always #8 clk = ~clk;

    reg [127:0] in_data = 0;
    reg [3:0] in_keep = 0;
    reg [8:0] in_user = 0;
    reg in_last = 0, in_valid = 0;
    wire [127:0] out_data;
    wire [3:0] out_keep;
    wire [8:0] out_user;
    wire out_last, out_valid;

    wire [7:0] lk_tag, lk_host_tag, up_tag;
    wire [1:0] lk_state, lk_attr;
    wire lk_superseded;
    wire [12:0] lk_remaining, up_remaining;
    wire [6:0] lk_next_la, up_next_la;
    wire [2:0] lk_tc;
    wire up_valid, up_retire, unexpected_valid;
    wire [95:0] unexpected_header;
    wire malformed_valid;
    wire [127:0] malformed_header;
    wire [15:0] completed_count, unexpected_count, mismatch_count;
    wire [15:0] bcm_count, crs_count, superseded_count, malformed_count;

    pcileech_req_rx_cpl dut (
        .clk(clk), .rst(rst), .flr(flr),
        .in_data(in_data), .in_keep(in_keep), .in_user(in_user),
        .in_last(in_last), .in_valid(in_valid),
        .out_data(out_data), .out_keep(out_keep), .out_user(out_user),
        .out_last(out_last), .out_valid(out_valid),
        .lk_tag(lk_tag), .lk_state(lk_state), .lk_host_tag(lk_host_tag),
        .lk_superseded(lk_superseded), .lk_remaining(lk_remaining),
        .lk_next_la(lk_next_la), .lk_tc(lk_tc), .lk_attr(lk_attr),
        .up_tag(up_tag), .up_valid(up_valid), .up_retire(up_retire),
        .up_remaining(up_remaining), .up_next_la(up_next_la),
        .unexpected_valid(unexpected_valid), .unexpected_header(unexpected_header),
        .malformed_valid(malformed_valid), .malformed_header(malformed_header),
        .completed_count(completed_count), .unexpected_count(unexpected_count),
        .mismatch_count(mismatch_count), .bcm_count(bcm_count),
        .crs_count(crs_count), .superseded_count(superseded_count),
        .malformed_count(malformed_count)
    );

    reg adm_valid = 0, iss_valid = 0, ctl_disable = 1;
    reg [7:0] adm_tag = 0, adm_host_tag = 0, iss_tag = 0;
    reg [12:0] adm_bc = 0;
    reg [6:0] adm_la = 0;
    wire [255:0] free;
    wire to_valid;
    wire [8:0] n_reserved, n_issued, n_quarantined;
    pcileech_req_table #(.TICK_CYCLES(1), .W(34)) entries (
        .clk(clk), .rst(rst), .flr(flr), .ctl_code(4'd1), .ctl_disable(ctl_disable),
        .adm_valid(adm_valid), .adm_tag(adm_tag), .adm_host_tag(adm_host_tag),
        .adm_bc(adm_bc), .adm_la(adm_la), .adm_tc(3'd5), .adm_attr(2'd2),
        .iss_valid(iss_valid), .iss_tag(iss_tag), .rel_valid(1'b0), .rel_tag(8'd0),
        .lk_tag(lk_tag), .lk_state(lk_state), .lk_host_tag(lk_host_tag),
        .lk_superseded(lk_superseded), .lk_remaining(lk_remaining),
        .lk_next_la(lk_next_la), .lk_tc(lk_tc), .lk_attr(lk_attr),
        .up_valid(up_valid), .up_tag(up_tag), .up_retire(up_retire),
        .up_remaining(up_remaining), .up_next_la(up_next_la),
        .free(free), .to_valid(to_valid), .to_tag(), .n_reserved(n_reserved),
        .n_issued(n_issued), .n_quarantined(n_quarantined), .trn_pending(),
        .err_bypass(), .err_release()
    );

    int checks = 0;
    task automatic check(input logic ok, input string message);
        checks++;
        if (ok !== 1'b1)
            $fatal(1, "R1_TB_FAIL %s", message);
    endtask

    task automatic request(
        input [7:0] tag, input [7:0] host_tag, input [12:0] bytes,
        input [6:0] la, input bit issue_it = 1
    );
        @(negedge clk);
        adm_valid = 1; adm_tag = tag; adm_host_tag = host_tag;
        adm_bc = bytes; adm_la = la; in_valid = 0;
        @(negedge clk);
        adm_valid = 0; iss_tag = tag; iss_valid = issue_it;
        @(negedge clk);
        iss_valid = 0;
    endtask

    function automatic [127:0] header(
        input [7:0] tag, input [11:0] bc, input [6:0] la, input [9:0] length_dw,
        input [7:0] fmt_type = 8'h4a, input [2:0] status = 0,
        input bit td = 0, input bit ep = 0, input bit bcm = 0
    );
        header = {32'hdeadbeef, 16'h0218, tag, 1'b0, la, 16'h0020,
                  status, bcm, bc, fmt_type, 1'b0, 3'd5, 4'd0, td, ep,
                  2'd2, 2'd0, length_dw};
    endfunction

    function automatic [3:0] mask(input integer words);
        case (words)
            1: mask = 4'h1;
            2: mask = 4'h3;
            3: mask = 4'h7;
            default: mask = 4'hf;
        endcase
    endfunction

    task automatic send(
        input [127:0] data, input [3:0] keep, input bit first, input bit last,
        input bit deliver, input [127:0] expected, input [3:0] expected_keep,
        input bit expected_last, input bit update_entry = 0, input bit retire = 0,
        input [12:0] bytes_left = 0, input [6:0] next_la = 0,
        input bit unexpected = 0, input bit malformed = 0
    );
        @(negedge clk);
        in_data = data; in_keep = keep; in_user = {7'h35, last, first};
        in_last = last; in_valid = 1;
        #1;
        check(up_valid === update_entry, "one update per matching completion");
        if (update_entry) begin
            check(up_tag === data[79:72] && up_retire === retire, "update uses internal tag and expected retirement");
            if (!retire)
                check(up_remaining === bytes_left && up_next_la === next_la, "partial completion progress and next address");
        end
        check(unexpected_valid === unexpected, "unexpected event policy");
        check(malformed_valid === malformed, "malformed encoding and frame event policy");
        if (malformed)
            check(malformed_header === data, "malformed event retains the full original header");
        if (unexpected)
            check(unexpected_header === data[95:0], "error header retains original internal tag and fields");
        @(posedge clk);
        #1;
        check(out_valid === deliver, "fixed-latency packet delivery");
        if (deliver) begin
            check(out_keep === expected_keep && out_last === expected_last &&
                  out_user === {7'h35, expected_last, first}, "RX byte enables and packet boundaries");
            for (int lane = 0; lane < 4; lane++)
                if (expected_keep[lane])
                    check(out_data[32*lane +: 32] === expected[32*lane +: 32],
                          "forwarded DW with correct tag, EP, TD and payload");
        end
    endtask

    // Explicit wire DW count makes the scoreboard independent of the DUT's
    // length decoder. The expected stream excludes the optional last digest DW.
    task automatic cpl(
        input [127:0] hdr, input int wire_dw, input bit deliver,
        input [7:0] host_tag = 0, input bit update_entry = 0, input bit retire = 0,
        input [12:0] bytes_left = 0, input [6:0] next_la = 0, input bit unexpected = 0
    );
        logic [127:0] data, expected;
        int body_dw;
        body_dw = wire_dw - (hdr[15] ? 1 : 0);
        for (int offset = 0; offset < wire_dw; offset += 4) begin
            if (hdr[15] && offset == 4) begin
                @(negedge clk);
                in_valid = 0;
                @(posedge clk);
                #1;
                check(!out_valid && !up_valid, "RX gap cannot forward or update");
            end
            data = offset == 0 ? hdr : {32'hf1234567, 32'hdecafbad, 32'h23000000, 32'(offset)};
            expected = data;
            if (offset == 0) begin
                expected[79:72] = host_tag;
                expected[15] = 0;
            end
            send(data, mask(wire_dw - offset), offset == 0, offset + 4 >= wire_dw,
                 deliver && offset < body_dw, expected, mask(body_dw - offset),
                 offset + 4 >= body_dw, update_entry && offset == 0, retire,
                 bytes_left, next_la, unexpected && offset == 0);
        end
    endtask

    reg [127:0] hdr;
    initial begin
        repeat (2) @(negedge clk);
        rst = 0;
        // Untracked multi-beat packet with a completion-looking continuation.
        hdr = 128'h01020304_11223344_55667788_40000002;
        send(hdr, 4'hf, 1, 0, 1, hdr, 4'hf, 0);
        hdr = header(8'h12, 4, 0, 1);
        send(hdr, 4'h1, 0, 1, 1, hdr, 4'h1, 1);
        cpl(header(8'h12, 4, 0, 1), 4, 0, 0, 0, 0, 0, 0, 1); // FREE
        request(8'h12, 8'hac, 4, 0, 0);
        cpl(header(8'h12, 4, 0, 1), 4, 0, 0, 0, 0, 0, 0, 1); // RESERVED
        check(n_reserved == 1 && !free[8'h12], "completion cannot retire RESERVED");
        // PG054 assigns invalid 4DW completion format checking to user logic.
        hdr = header(8'h12, 8, 0, 2, 8'h6a);
        send(hdr, 4'hf, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);
        send(header(8'h13, 4, 0, 1), 4'h3, 0, 1, 0, 0, 0, 0);
        check(malformed_count == 1, "invalid completion encoding counted once per packet");

        // EP on every fragment of one split read. LA wraps modulo 128.
        request(8'h13, 8'had, 133, 7'h7f);
        cpl(header(8'h13, 133, 7'h7f, 1, 8'h4a, 0, 0, 1), 4, 1, 8'had, 1, 0, 132, 0);
        check(!free[8'h13], "poisoned first fragment retains tag");
        cpl(header(8'h13, 133, 7'h7f, 1), 4, 0, 0, 0, 0, 0, 0, 1); // duplicate
        cpl(header(8'h13, 132, 0, 32, 8'h4a, 0, 0, 1), 35, 1, 8'had, 1, 0, 4, 0);
        check(!free[8'h13], "poisoned middle fragment retains tag");
        cpl(header(8'h13, 4, 0, 1, 8'h4a, 0, 0, 1), 4, 1, 8'had, 1, 1);
        check(free[8'h13], "poisoned final fragment retires tag");

        request(8'h14, 8'hae, 4, 0);
        hdr = header(8'h14, 4, 0, 1);
        hdr[22:20] = 3'd1;
        cpl(hdr, 4, 0, 0, 0, 0, 0, 0, 1);
        hdr = header(8'h14, 4, 0, 1);
        hdr[13:12] = 2'd1;
        cpl(hdr, 4, 0, 0, 0, 0, 0, 0, 1);
        cpl(header(8'h14, 3, 0, 1), 4, 0, 0, 0, 0, 0, 0, 1);
        cpl(header(8'h14, 4, 4, 1), 4, 0, 0, 0, 0, 0, 0, 1);
        cpl(header(8'h14, 4, 0, 2), 5, 0, 0, 0, 0, 0, 0, 1);
        cpl(header(8'h14, 4, 0, 1, 8'h4b), 4, 0, 0, 0, 0, 0, 0, 1);
        cpl(header(8'h14, 4, 0, 1, 8'h0a), 3, 0, 0, 0, 0, 0, 0, 1);
        send(header(8'h14, 4, 0, 1), 4'h7, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);
        check(unexpected_count == 10 && mismatch_count == 8 && malformed_count == 2,
              "unowned and malformed completions have distinct counters");
        cpl(header(8'h14, 4, 0, 1, 8'h4a, 0, 0, 0, 1), 4, 0);
        check(bcm_count == 1 && !free[8'h14], "BCM is counted without retiring or reporting");
        // TD on a one-DW read creates a digest-only beat after the packet body.
        cpl(header(8'h14, 4, 0, 1, 8'h4a, 0, 1), 5, 1, 8'hae, 1, 1);
        check(free[8'h14], "untrimmed digest does not impede retirement");

        request(8'h15, 8'hb5, 8, 0);
        cpl(header(8'h15, 8, 0, 2, 8'h4a, 0, 1), 6, 1, 8'hb5, 1, 1);
        request(8'h15, 8'hb5, 12, 0);
        cpl(header(8'h15, 12, 0, 3, 8'h4a, 0, 1), 7, 1, 8'hb5, 1, 1);
        request(8'h16, 8'hb6, 1, 0); // zero-length read encoding
        cpl(header(8'h16, 1, 0, 1), 4, 1, 8'hb6, 1, 1);
        request(8'h17, 8'hb7, 4096, 0);
        cpl(header(8'h17, 0, 0, 0, 8'h4a, 0, 1), 1028, 1, 8'hb7, 1, 1);
        check(free[8'h17], "encoded zero length and byte count support 4096 bytes");

        // All non-SC statuses terminate a matching request. Length is undefined.
        for (int s = 1; s < 8; s++) begin
            request(8'h20, 8'hb8, 4, 0);
            cpl(header(8'h20, 4, 0, 10'h2ff, 8'h0a, 3'(s), 1),
                4, s != 2, 8'hb8, 1, 1);
            check(free[8'h20], "terminal completion retires independent of undefined Length");
        end
        check(crs_count == 1, "CRS is counted without PCIe error signaling");
        request(8'h21, 8'hb9, 4, 0);
        cpl(header(8'h21, 4, 0, 1, 8'h4a, 3'd4), 4, 0, 0, 0, 0, 0, 0, 1);
        hdr = header(8'h21, 4, 0, 1, 8'h0a, 3'd4);
        hdr[22:20] = 3'd4;
        cpl(hdr, 3, 0, 0, 0, 0, 0, 0, 1);
        check(!free[8'h21], "non-success CplD cannot retire");

        // Same-edge host tag reuse suppresses old delivery while still retiring it.
        request(8'h22, 8'hc1, 4, 0);
        @(posedge clk);
        #1;
        adm_valid = 1; adm_tag = 8'h23; adm_host_tag = 8'hc1; adm_bc = 4; adm_la = 0;
        cpl(header(8'h22, 4, 0, 1), 4, 0, 0, 1, 1);
        adm_valid = 0;
        check(free[8'h22] && !free[8'h23] && superseded_count == 1,
              "superseded completion retires without delivery");

        request(8'h24, 8'hc2, 8, 7'h7c);
        @(negedge clk);
        in_valid = 0; flr = 1;
        @(negedge clk);
        flr = 0;
        cpl(header(8'h24, 8, 7'h7c, 1), 4, 0, 0, 1, 0, 4, 0, 1);
        cpl(header(8'h24, 4, 0, 1), 4, 0, 0, 1, 1, 0, 0, 1);
        check(free[8'h24], "late fragments progress and retire without host delivery");
        request(8'h2a, 8'hca, 4, 0);
        @(negedge clk);
        in_valid = 0; flr = 1;
        @(negedge clk);
        flr = 0;
        cpl(header(8'h2a, 4, 0, 1, 8'h4a, 0, 0, 0, 1), 4, 0, 0, 0, 0, 0, 0, 1);
        cpl(header(8'h2a, 4, 0, 1, 8'h0a, 3'd2), 3, 0, 0, 1, 1, 0, 0, 1);
        check(free[8'h2a], "quarantined CRS retires and remains unexpected");

        request(8'h25, 8'hc5, 8, 7'h7c);
        request(8'h28, 8'hc8, 4, 0);
        @(posedge clk);
        #1;
        flr = 1;
        cpl(header(8'h25, 8, 7'h7c, 1), 4, 0, 0, 1, 0, 4, 0, 1);
        flr = 0;
        cpl(header(8'h25, 4, 0, 1), 4, 0, 0, 1, 1, 0, 0, 1);
        cpl(header(8'h28, 4, 0, 1), 4, 0, 0, 1, 1, 0, 0, 1);
        check(free[8'h25] && free[8'h28], "partial on FLR edge progresses in quarantine");

        request(8'h29, 8'hc9, 4, 0);
        @(posedge clk);
        #1;
        flr = 1;
        cpl(header(8'h29, 4, 0, 1), 4, 1, 8'hc9, 1, 1);
        flr = 0;
        check(free[8'h29], "terminal completion wins on FLR edge");

        // At the expiry edge the final completion wins. The cycle counter is
        // advanced until this tag's first due sweep, without asserting RX early.
        @(negedge clk);
        ctl_disable = 0; in_valid = 0;
        request(8'h26, 8'hc3, 4, 0);
        while (!(entries.sw_idx == 8'h26 && entries.sw_expire)) @(negedge clk);
        in_data = header(8'h26, 4, 0, 1);
        in_keep = 4'hf; in_user = 9'd3; in_last = 1; in_valid = 1;
        #1;
        check(up_valid && up_retire && !unexpected_valid, "final completion is accepted on the due sweep");
        @(posedge clk);
        #1;
        check(free[8'h26] && !to_valid && out_valid && out_data[79:72] == 8'hc3,
              "final completion wins over same-edge timeout");
        check(completed_count == 16 && unexpected_count == 19 && mismatch_count == 10 &&
              bcm_count == 2 && crs_count == 2 && superseded_count == 1 && malformed_count == 2,
              "completion telemetry counts active retirement, late traffic and each drop reason");

        // Reset must discard a continuation and resume at the next first beat.
        hdr = 128'h01020304_11223344_55667788_40000002;
        send(hdr, 4'hf, 1, 0, 1, hdr, 4'hf, 0);
        @(negedge clk);
        rst = 1;
        @(posedge clk);
        #1;
        check(!out_valid && !up_valid && !unexpected_valid, "session reset clears RX pipeline");
        @(negedge clk);
        rst = 0; in_valid = 0;
        send(hdr, 4'h1, 0, 1, 0, 0, 0, 0);
        send(hdr, 4'hf, 1, 1, 1, hdr, 4'hf, 1);
        check(completed_count == 0 && unexpected_count == 0 && mismatch_count == 0 &&
              bcm_count == 0 && crs_count == 0 && superseded_count == 0 && malformed_count == 0 &&
              n_reserved == 0 && n_issued == 0 && n_quarantined == 0,
              "session reset clears counters and table");
        @(negedge clk);
        in_data = header(8'h26, 4, 0, 1);
        in_keep = 4'hf; in_user = 9'd3; in_last = 1; in_valid = 1;
        repeat (65537) @(posedge clk);
        #1;
        check(unexpected_count == 16'hffff && mismatch_count == 0 && !out_valid,
              "unexpected telemetry saturates while dropping unowned completions");
        $display("R1_TB_PASS tb_req_rx_cpl checks=%0d", checks);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "R1_TB_FAIL watchdog");
    end
endmodule
