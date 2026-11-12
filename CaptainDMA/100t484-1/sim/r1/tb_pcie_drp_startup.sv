// R1 reset-held DRP startup: sequence, failures, re-run per reset, and the
// shared host bridge. The core model checks the DRP port protocol (one-cycle
// drp_en, no new request before drp_rdy) and keeps a 512-word register file.
`timescale 1ns / 1ps
module tb_pcie_drp_startup;
    // Bits outside the plan mask that startup compares with the expected base.
    // 65295 = 16'hff0f checks every non-plan bit; 3840 = 16'h0f00 checks one
    // field only (like the board's Completion Timeout Ranges field).
    parameter integer CHECK = 65295;
    localparam [8:0]  ADDR  = 9'h019;
    localparam [15:0] MASK  = 16'h00f0;
    localparam [15:0] VALUE = 16'h0050;
    localparam [15:0] BASE  = 16'h1203;          // bits outside MASK
    localparam [15:0] IP_DEFAULT = BASE | 16'h0020;
    localparam [15:0] PLANNED = BASE | VALUE;
    localparam integer TIMEOUT = 64;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_src = 1'b1;
    reg host_en = 1'b0, host_we = 1'b0;
    reg [8:0] host_addr = 9'd0;
    reg [15:0] host_di = 16'd0;
    wire host_rdy, drp_ok, failed;
    wire [15:0] host_do, read_word, verify_word;
    wire drp_en, drp_we, drp_rdy;
    wire [8:0] drp_addr;
    wire [15:0] drp_di, drp_do;
    wire [1:0] fail_reason;
    wire [7:0] fail_count, host_refused_count, host_timeout_count;
    wire fail_sticky;

    pcileech_pcie_drp_startup #(
        .PLAN_BOUND(1), .PLAN_ADDR(ADDR), .PLAN_MASK(MASK), .PLAN_VALUE(VALUE),
        .PLAN_CHECK_MASK(16'(CHECK)), .PLAN_BASE_EXPECT(BASE & 16'(CHECK)),
        .RDY_TIMEOUT_CYCLES(TIMEOUT)
    ) dut (
        .clk(clk), .rst_src(rst_src), .drp_ok(drp_ok),
        .host_en(host_en), .host_we(host_we), .host_addr(host_addr), .host_di(host_di),
        .host_rdy(host_rdy), .host_do(host_do),
        .drp_en(drp_en), .drp_we(drp_we), .drp_addr(drp_addr), .drp_di(drp_di),
        .drp_rdy(drp_rdy), .drp_do(drp_do),
        .failed(failed), .fail_reason(fail_reason), .fail_count(fail_count),
        .read_word(read_word), .verify_word(verify_word),
        .host_refused_count(host_refused_count), .host_timeout_count(host_timeout_count),
        .fail_sticky(fail_sticky));

    integer errors = 0, checks = 0;
    task automatic fail(input [8*72-1:0] what);
        begin
            errors = errors + 1;
            if (errors < 20) $display("R1_TB_FAIL tb_pcie_drp_startup %0s @%0t", what, $time);
        end
    endtask
    task automatic check_that(input cond, input [8*72-1:0] what);
        begin
            checks = checks + 1;
            if (!cond) fail(what);
        end
    endtask

    // ---- DRP core model ----
    reg [15:0] regs[0:511];
    reg        busy = 1'b0, m_we = 1'b0, m_rdy = 1'b0;
    reg [8:0]  m_addr = 9'd0;
    reg [15:0] m_di = 16'd0, m_do = 16'd0;
    integer    countdown = 0, max_lat = 6, age = 0;
    reg        mute = 1'b0, drop_writes = 1'b0, en_prev = 1'b0;
    reg [15:0] write_xor = 16'd0;    // fault: write lands with these bits flipped
    integer    n_reads = 0, n_writes = 0, n_plan_writes = 0;
    assign drp_rdy = m_rdy;
    assign drp_do = m_do;
    integer j;
    initial for (j = 0; j < 512; j = j + 1) regs[j] = 16'(j * 16'h0101);
    always @(posedge clk) begin
        m_rdy <= 1'b0;
        en_prev <= drp_en;
        if (drp_en && en_prev) fail("drp_en held for two cycles");
        age <= busy ? age + 1 : 0;
        if (drp_en) begin
            // A request may only replace an outstanding one the controller has
            // abandoned: at least its timeout window plus the drain window.
            if (busy && age < 2 * TIMEOUT) fail("new DRP request before drp_rdy");
            age <= 0;
            busy <= 1'b1; m_we <= drp_we; m_addr <= drp_addr; m_di <= drp_di;
            countdown <= 1 + ($urandom % max_lat);
            if (drp_we) begin
                n_writes = n_writes + 1;
                if (drp_addr == ADDR) n_plan_writes = n_plan_writes + 1;
            end else n_reads = n_reads + 1;
        end else if (busy && !mute) begin
            if (countdown <= 1) begin
                busy <= 1'b0;
                m_rdy <= 1'b1;
                if (m_we) begin
                    if (!drop_writes) regs[m_addr] <= m_di ^ write_xor;
                    m_do <= 16'hxxxx;
                end else m_do <= regs[m_addr];
            end else countdown <= countdown - 1;
        end
    end

    // ---- bridge-side checks: one rdy per en ----
    integer host_outstanding = 0;
    always @(posedge clk) begin
        if (host_en) host_outstanding = host_outstanding + 1;
        if (host_rdy) begin
            if (host_outstanding == 0) fail("host rdy without request");
            host_outstanding = host_outstanding - 1;
        end
    end
    // drp_ok never high while a reset source is asserted (registered: one edge late)
    reg rst_src_d = 1'b1;
    always @(posedge clk) begin
        if (rst_src_d && drp_ok) fail("drp_ok while reset source asserted");
        rst_src_d <= rst_src;
    end

    // drp_ok may rise only after a read and a verify read both issued after the
    // last reset-source release (an aborted attempt must not count).
    integer reads_since_release = 0;
    reg drp_ok_d = 1'b0;
    always @(posedge clk) begin
        if (rst_src) reads_since_release = 0;
        else if (drp_en && !drp_we && drp_addr == ADDR) reads_since_release = reads_since_release + 1;
        if (drp_ok && !drp_ok_d) begin
            checks = checks + 1;
            if (reads_since_release < 2) fail("drp_ok without a full attempt after release");
        end
        drp_ok_d <= drp_ok;
    end

    task automatic cycles(input integer n);
        repeat (n) @(posedge clk);
    endtask
    task automatic reset_pulse(input integer n);
        begin
            @(negedge clk) rst_src = 1'b1;
            cycles(n);
            @(negedge clk) rst_src = 1'b0;
        end
    endtask
    task automatic wait_done(output integer took);
        begin
            took = 0;
            @(posedge clk); #1;      // the attempt starts here and clears a stale failed
            while (!drp_ok && !(failed && dut.state == 0) && took < 2000) begin
                @(posedge clk); took = took + 1;
            end
            #1;
        end
    endtask
    task automatic host_op(input we, input [8:0] addr, input [15:0] di, output [15:0] got);
        integer t;
        begin
            @(negedge clk);
            host_en = 1'b1; host_we = we; host_addr = addr; host_di = di;
            @(negedge clk) host_en = 1'b0;
            t = 0;
            while (!host_rdy && t < 4000) begin @(posedge clk); #1; t = t + 1; end
            check_that(host_rdy, "host request answered");
            got = host_do;
            @(negedge clk);
        end
    endtask

    // Watchdog: a passing run takes about 30 us of simulated time.
    initial begin
        #2_000_000;
        $display("R1_TB_FAIL tb_pcie_drp_startup watchdog: bench stuck");
        $display("R1_TB_FAILED tb_pcie_drp_startup errors=%0d", errors + 1);
        $finish;
    end

    integer took, r0, w0, i;
    reg [15:0] got;
    initial begin
        regs[ADDR] = IP_DEFAULT;
        // 1. Held in reset: nothing happens, drp_ok low.
        cycles(20);
        check_that(!drp_ok && n_reads == 0, "idle while reset source held");
        // 2. Power-up sequence: read, write planned bits, verify.
        @(negedge clk) rst_src = 1'b0;
        wait_done(took);
        check_that(drp_ok && !failed, "power-up plan applied");
        check_that(regs[ADDR] == PLANNED, "planned word written");
        check_that(read_word == IP_DEFAULT && verify_word == PLANNED, "status words");
        check_that(n_reads == 2 && n_plan_writes == 1, "read/write/verify count");
        // 3. drp_ok drops on every reset source and the sequence re-runs; the
        //    word already matches, so no write.
        r0 = n_reads; w0 = n_writes;
        reset_pulse(1);
        #1 check_that(!drp_ok, "drp_ok cleared by one-cycle reset source");
        wait_done(took);
        check_that(drp_ok && n_reads == r0 + 2 && n_writes == w0, "re-run verifies without writing");
        // 4. Core reset reverts the register: re-run writes again.
        reset_pulse(5);
        regs[ADDR] = IP_DEFAULT;
        wait_done(took);
        check_that(drp_ok && regs[ADDR] == PLANNED, "re-run rewrites after core reset");
        // 5. Base mismatch: refuse, no write, held in reset, retry next episode.
        regs[ADDR] = 16'h3303 | 16'h0020;
        w0 = n_plan_writes;
        reset_pulse(3);
        wait_done(took);
        check_that(!drp_ok && failed && fail_reason == 2'd2 && fail_count == 8'd1, "base mismatch refused");
        check_that(n_plan_writes == w0 && regs[ADDR] == (16'h3303 | 16'h0020), "no write on base mismatch");
        cycles(200);
        check_that(!drp_ok, "failure holds reset without a new reset source");
        regs[ADDR] = IP_DEFAULT;
        reset_pulse(2);
        wait_done(took);
        check_that(drp_ok && !failed && fail_reason == 2'd0 && fail_count == 8'd1, "retry after failure");
        // 6. Verify mismatch: write does not stick.
        drop_writes = 1'b1;
        regs[ADDR] = IP_DEFAULT;
        reset_pulse(2);
        wait_done(took);
        check_that(!drp_ok && failed && fail_reason == 2'd3 && verify_word == IP_DEFAULT, "verify mismatch");
        drop_writes = 1'b0;
        // 6b. Write lands but disturbs a bit outside the plan mask.
        write_xor = 16'h0100;
        regs[ADDR] = IP_DEFAULT;
        reset_pulse(2);
        wait_done(took);
        check_that(!drp_ok && failed && fail_reason == 2'd3 && verify_word == (PLANNED ^ 16'h0100),
                   "whole-word verify catches base corruption");
        write_xor = 16'd0;
        // 7. rdy timeout.
        mute = 1'b1;
        reset_pulse(2);
        wait_done(took);
        check_that(!drp_ok && failed && fail_reason == 2'd1, "rdy timeout");
        // timeout window, then the drain window before the port is reusable
        check_that(took >= 2 * TIMEOUT && took <= 2 * TIMEOUT + 4, "timeout after RDY_TIMEOUT_CYCLES");
        mute = 1'b0;            // the stale request completes; nothing else outstanding
        cycles(20);
        // 8. Reset source in the middle of each transaction: abort, re-run.
        for (i = 0; i < 3; i = i + 1) begin
            regs[ADDR] = IP_DEFAULT;
            max_lat = 30;
            reset_pulse(2);
            while (dut.state != 3'(1 + i)) @(posedge clk);
            reset_pulse(1);
            wait_done(took);
            check_that(drp_ok && regs[ADDR] == PLANNED && !failed, "abort mid-transaction then re-run");
        end
        max_lat = 6;
        // 9. Host bridge: requests during startup are deferred and served.
        regs[ADDR] = IP_DEFAULT;
        regs[9'h040] = 16'hbeef;
        max_lat = 20;
        reset_pulse(2);
        cycles(2);
        host_op(1'b0, 9'h040, 16'd0, got);
        check_that(got == 16'hbeef, "host read deferred behind startup");
        wait_done(took);
        check_that(drp_ok, "startup completes with host traffic");
        max_lat = 6;
        host_op(1'b1, 9'h041, 16'h1234, got);
        check_that(regs[9'h041] == 16'h1234, "host write to other address");
        host_op(1'b0, ADDR, 16'd0, got);
        check_that(got == PLANNED, "host read of plan address");
        host_op(1'b1, ADDR, 16'h0000, got);
        check_that(regs[ADDR] == PLANNED && host_refused_count == 8'd1 && got == 16'd0,
               "host write to plan address refused");
        // Host write to plan address during startup: refused, startup unaffected.
        regs[ADDR] = IP_DEFAULT;
        reset_pulse(2);
        cycles(1);
        host_op(1'b1, ADDR, 16'hffff, got);
        wait_done(took);
        check_that(drp_ok && regs[ADDR] == PLANNED && host_refused_count == 8'd2,
               "plan write refused during startup");
        // 11. Review F3: host request latched while the reset source is held,
        //     DRP ready withheld. The host transaction is bounded (answered
        //     0xFFFF and counted), the port drains, and startup then runs and
        //     reports its own timeout instead of hanging in HOST.
        regs[ADDR] = IP_DEFAULT;
        w0 = fail_count;
        @(negedge clk) rst_src = 1'b1;
        cycles(2);
        mute = 1'b1;
        host_op(1'b0, 9'h040, 16'd0, got);
        check_that(got == 16'hffff && host_timeout_count == 8'd1, "stalled host DRP answered and counted");
        @(negedge clk) rst_src = 1'b0;
        wait_done(took);
        check_that(!drp_ok && failed && fail_reason == 2'd1 && fail_count == 8'(w0 + 1),
                   "startup after stalled host reports timeout");
        check_that(took <= 4 * TIMEOUT + 16, "startup failure bounded after stalled host");
        mute = 1'b0;            // the stale transaction completes and is absorbed
        cycles(3 * TIMEOUT);
        reset_pulse(2);
        wait_done(took);
        check_that(drp_ok && !failed && fail_sticky, "retry after stall succeeds; sticky failure kept");
        // 12. Late ready after a host timeout lands in the drain window and is
        //     absorbed: it must not answer the next startup read.
        regs[ADDR] = IP_DEFAULT;
        regs[9'h040] = 16'h7777;
        @(negedge clk) rst_src = 1'b1;
        cycles(2);
        mute = 1'b1;
        fork
            host_op(1'b0, 9'h040, 16'd0, got);
            begin
                while (host_timeout_count != 8'd2) @(posedge clk);
                cycles(2);
                mute = 1'b0;            // stale response arrives during the drain
            end
        join
        check_that(got == 16'hffff, "timed-out host read answered 0xFFFF");
        @(negedge clk) rst_src = 1'b0;
        wait_done(took);
        check_that(drp_ok && read_word == IP_DEFAULT && regs[ADDR] == PLANNED,
                   "late ready absorbed, startup reads the plan word");
        // 13. Reset-source assertion during a long host transaction does not
        //     wedge startup: host is answered normally, startup follows.
        regs[ADDR] = IP_DEFAULT;
        max_lat = 30;
        @(negedge clk);
        host_en = 1'b1; host_we = 1'b0; host_addr = 9'h040; host_di = 16'd0;
        @(negedge clk) host_en = 1'b0;
        reset_pulse(1);
        while (!host_rdy) @(posedge clk);
        #1 check_that(host_do == 16'h7777, "host answered across reset pulse");
        wait_done(took);
        check_that(drp_ok && regs[ADDR] == PLANNED, "startup runs after host transaction");
        max_lat = 6;
        // 14. Bits outside the check mask: refused when checked, tolerated and
        //     preserved when not (field-only check, contract section 11).
        regs[ADDR] = IP_DEFAULT ^ 16'h1001;     // bits 12 and 0, outside MASK
        reset_pulse(2);
        wait_done(took);
        if (CHECK == 65295)
            check_that(!drp_ok && failed && fail_reason == 2'd2, "full check refuses other bits");
        else
            check_that(drp_ok && !failed && regs[ADDR] == (((IP_DEFAULT ^ 16'h1001) & ~MASK) | VALUE),
                       "unchecked bits tolerated and preserved");
        // 10. Saturating failure count.
        regs[ADDR] = 16'h0000;
        for (i = 0; i < 260; i = i + 1) begin
            reset_pulse(1);
            wait_done(took);
        end
        check_that(fail_count == 8'hff && failed, "fail count saturates");
        cycles(10);
        check_that(host_outstanding == 0, "every host request answered once");

        if (errors == 0)
            $display("R1_TB_PASS tb_pcie_drp_startup checks=%0d", checks);
        else
            $display("R1_TB_FAILED tb_pcie_drp_startup errors=%0d", errors);
        $finish;
    end
endmodule
