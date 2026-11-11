// TX observer with the real requester table and a core-side AXI handshake.
`timescale 1ns / 1ps
`include "pcileech_req_defs.svh"

module tb_req_tx_obs;
    localparam int TIMEOUT_TICKS = 5625;
    localparam int SWEEP_CYCLES = 256;
    reg clk = 0, rst = 1;
    always #8 clk = ~clk;

    reg [63:0] tx_data = 0;
    reg tx_valid = 0, tx_ready = 0, tx_last = 0, tx_err_drop = 0;
    wire iss_valid;
    wire [7:0] iss_tag;
    wire [15:0] tx_drop_count;

    pcileech_req_tx_obs observer (
        .clk(clk), .rst(rst), .tx_data(tx_data),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_last(tx_last),
        .tx_err_drop(tx_err_drop), .iss_valid(iss_valid),
        .iss_tag(iss_tag), .tx_drop_count(tx_drop_count)
    );

    reg adm_valid = 0, flr = 0;
    reg [7:0] adm_tag = 0, lk_tag = 0;
    wire [1:0] lk_state;
    wire [255:0] free;
    wire to_valid, err_bypass, err_release;
    wire [7:0] to_tag;

    pcileech_req_table #(.TICK_CYCLES(1), .W(34)) entries (
        .clk(clk), .rst(rst), .flr(flr), .ctl_code(4'd1), .ctl_disable(1'b0),
        .adm_valid(adm_valid), .adm_tag(adm_tag), .adm_host_tag(adm_tag),
        .adm_bc(13'd4), .adm_la(7'd0), .adm_tc(3'd0), .adm_attr(2'd0),
        .iss_valid(iss_valid), .iss_tag(iss_tag), .rel_valid(1'b0), .rel_tag(8'd0),
        .lk_tag(lk_tag), .lk_state(lk_state), .lk_host_tag(), .lk_superseded(),
        .lk_remaining(), .lk_next_la(), .lk_tc(), .lk_attr(),
        .up_valid(1'b0), .up_tag(8'd0), .up_retire(1'b0),
        .up_remaining(13'd0), .up_next_la(7'd0), .free(free),
        .to_valid(to_valid), .to_tag(to_tag), .n_reserved(), .n_issued(),
        .n_quarantined(), .trn_pending(), .err_bypass(err_bypass),
        .err_release(err_release)
    );

    int checks = 0, issues = 0, timeouts = 0;
    reg [7:0] last_timeout = 0;
    always @(posedge clk) if (!rst) begin
        if (iss_valid) issues <= issues + 1;
        if (to_valid) begin
            timeouts <= timeouts + 1;
            last_timeout <= to_tag;
        end
    end

    task automatic check(input logic ok, input string message);
        checks++;
        if (ok !== 1'b1)
            $fatal(1, "R1_TB_FAIL %s", message);
    endtask

    function automatic [63:0] header(input [7:0] fmt_type, input [7:0] tag);
        header = {16'h0218, tag, 8'h0f, fmt_type, 24'h000001};
    endfunction

    task automatic state(input [7:0] tag, input [1:0] want, input string message);
        lk_tag = tag;
        #1;
        check(lk_state === want && free[tag] === (want == `REQ_ST_FREE), message);
    endtask

    task automatic admit(input [7:0] tag);
        @(negedge clk);
        adm_valid = 1; adm_tag = tag;
        @(negedge clk);
        adm_valid = 0;
    endtask

    // Drives the next cycle at a falling edge. The caller can hold or continue
    // the beat over as many cycles as the AXI handshake requires.
    task automatic beat(
        input [63:0] data, input bit last, input bit valid, input bit ready
    );
        @(negedge clk);
        tx_data = data; tx_last = last; tx_valid = valid; tx_ready = ready;
        @(posedge clk);
        #1;
    endtask

    task automatic idle;
        beat(64'd0, 0, 0, 1);
    endtask

    task automatic read_packet(input [7:0] fmt_type, input [7:0] tag);
        beat(header(fmt_type, tag), 0, 1, 1);
        // The address word intentionally has header-like bits and a different tag.
        beat(header(8'h00, 8'hcc), 1, 1, 1);
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst = 0;
        admit(8'h12);
        beat(header(8'h00, 8'h12), 0, 1, 0);
        check(issues == 0, "stalled first word must not start a packet");
        beat(header(8'h00, 8'h12), 0, 1, 1);
        state(8'h12, `REQ_ST_RESERVED, "accepted header keeps reservation");
        // Long gap while the packet is open. A false last with valid=0 is inert.
        beat(header(8'h20, 8'hcc), 1, 0, 1);
        repeat (TIMEOUT_TICKS + SWEEP_CYCLES) @(negedge clk);
        check(timeouts == 0 && issues == 0, "completion timer has not started");
        beat(header(8'h00, 8'hcc), 1, 1, 0);
        repeat (3) @(posedge clk);
        #1;
        check(issues == 0, "stalled tlast cannot issue or consume packet context");
        beat(header(8'h00, 8'hcc), 1, 1, 1);
        state(8'h12, `REQ_ST_ISSUED, "accepted tlast issues the first word tag");
        check(issues == 1 && !err_bypass, "accepted read issues exactly once");

        @(negedge clk);
        tx_valid = 0; tx_err_drop = 1;
        @(negedge clk);
        tx_err_drop = 0;
        state(8'h12, `REQ_ST_ISSUED, "core drop never releases an issued tag");
        check(tx_drop_count == 1 && !err_release, "core drop updates only telemetry");
        repeat (TIMEOUT_TICKS - 4) @(negedge clk);
        check(timeouts == 0, "timeout does not precede accepted-tlast window");
        repeat (SWEEP_CYCLES + 8) @(negedge clk);
        check(timeouts == 1 && last_timeout == 8'h12, "dropped read times out normally");
        state(8'h12, `REQ_ST_QUARANTINED, "timeout quarantines the dropped read");

        admit(8'h34);
        admit(8'h56);
        read_packet(8'h20, 8'h34);
        read_packet(8'h00, 8'h56);
        state(8'h34, `REQ_ST_ISSUED, "4DW memory read decoded");
        state(8'h56, `REQ_ST_ISSUED, "back-to-back read starts a new packet");
        check(issues == 3 && !err_bypass, "both back-to-back reads issue once");

        // Non-read headers must never turn a payload word into an issue.
        beat(header(8'h40, 8'h56), 0, 1, 1);
        beat(header(8'h20, 8'h56), 1, 1, 1);
        beat(header(8'h4a, 8'h56), 0, 1, 1);
        beat(header(8'h00, 8'h56), 1, 1, 1);
        beat(header(8'h01, 8'h56), 0, 1, 1);
        beat(header(8'h00, 8'h56), 1, 1, 1);
        check(issues == 3 && !err_bypass, "posted, completion and locked read packets are untracked");

        read_packet(8'h00, 8'h87);
        state(8'h87, `REQ_ST_FREE, "unreserved read does not allocate a tag");
        check(issues == 4 && err_bypass, "unreserved read reaches the table bypass check");

        admit(8'h98);
        beat(header(8'h20, 8'h98), 0, 1, 1);
        @(negedge clk);
        flr = 1; tx_valid = 0;
        @(negedge clk);
        flr = 0;
        state(8'h98, `REQ_ST_RESERVED, "FLR keeps an open reservation");
        beat(header(8'h00, 8'hcc), 1, 1, 1);
        state(8'h98, `REQ_ST_QUARANTINED, "accepted post-FLR read quarantines its tag");

        admit(8'hab);
        beat(header(8'h00, 8'hab), 0, 1, 1);
        @(negedge clk);
        rst = 1; tx_last = 1; tx_ready = 1; tx_err_drop = 1;
        #1;
        check(!iss_valid, "reset masks coincident terminal handshake");
        @(negedge clk);
        rst = 0; tx_valid = 0; tx_err_drop = 0;
        check(tx_drop_count == 0 && !err_bypass, "session reset clears telemetry");
        state(8'hab, `REQ_ST_FREE, "session abort flushes the open reservation");
        admit(8'hbd);
        read_packet(8'h20, 8'hbd);
        idle();
        state(8'hbd, `REQ_ST_ISSUED, "next session decodes a new first word");
        check(!err_bypass, "next session cannot issue stale packet tag");

        @(negedge clk);
        tx_err_drop = 1;
        repeat (65537) @(negedge clk);
        tx_err_drop = 0;
        check(tx_drop_count == 16'hffff, "core drop counter saturates");
        $display("R1_TB_PASS tb_req_tx_obs checks=%0d", checks);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "R1_TB_FAIL watchdog");
    end
endmodule
