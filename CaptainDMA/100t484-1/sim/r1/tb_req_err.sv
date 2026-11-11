`timescale 1ns / 1ps
module tb_req_err;
    reg clk = 0, rst = 1;
    always #8 clk = ~clk;
    reg [1:0] power_state = 0;
    reg aer_enabled = 0, headerlog_set = 0;
    reg [31:0] aer_uncor_mask = 0;
    reg timeout_valid = 0, unexpected_valid = 0, malformed_valid = 0;
    reg [95:0] unexpected_header = 0;
    reg [127:0] malformed_header = 0;
    wire cfg_err_cpl_timeout, cfg_err_cpl_unexpect, cfg_err_malformed;
    wire cfg_err_posted, cfg_err_no_recovery, cfg_err_locked;
    wire [47:0] cfg_err_tlp_cpl_header;
    wire [127:0] cfg_err_aer_headerlog;
    wire [9:0] level, high_water;
    wire [15:0] reported_count, suppressed_count, overflow_count;
    wire err_overflow;

    pcileech_req_err dut (
        .clk(clk), .rst(rst), .power_state(power_state),
        .aer_enabled(aer_enabled), .headerlog_set(headerlog_set),
        .aer_uncor_mask(aer_uncor_mask),
        .timeout_valid(timeout_valid), .unexpected_valid(unexpected_valid),
        .unexpected_header(unexpected_header), .malformed_valid(malformed_valid),
        .malformed_header(malformed_header),
        .cfg_err_cpl_timeout(cfg_err_cpl_timeout),
        .cfg_err_cpl_unexpect(cfg_err_cpl_unexpect),
        .cfg_err_malformed(cfg_err_malformed), .cfg_err_posted(cfg_err_posted),
        .cfg_err_no_recovery(cfg_err_no_recovery), .cfg_err_locked(cfg_err_locked),
        .cfg_err_tlp_cpl_header(cfg_err_tlp_cpl_header),
        .cfg_err_aer_headerlog(cfg_err_aer_headerlog),
        .level(level), .high_water(high_water),
        .reported_count(reported_count), .suppressed_count(suppressed_count),
        .overflow_count(overflow_count), .err_overflow(err_overflow)
    );

    int checks = 0, emitted = 0, expected_reports = 0;
    reg [1:0] expected_type[0:4095];
    reg [127:0] expected_aer[0:4095];
    reg monitor_enabled = 1;
    reg [127:0] held_header;
    localparam [95:0] UNEXPECTED = 96'h0218a144_00200004_4a000001;
    localparam [127:0] MALFORMED = 128'h01234567_0218b155_00300008_6a000002;
    localparam [127:0] UNEXPECTED_AER = 128'h4a000001_00200004_0218a144_00000000;
    localparam [127:0] MALFORMED_AER = 128'h6a000002_00300008_0218b155_01234567;

    task automatic check(input logic ok, input string message);
        checks++;
        if (ok !== 1'b1)
            $fatal(1, "R1_TB_FAIL %s", message);
    endtask

    task automatic expect_report(input [1:0] kind, input [127:0] header);
        expected_type[expected_reports] = kind;
        expected_aer[expected_reports] = header;
        expected_reports++;
    endtask

    always @(posedge clk) if (!rst && monitor_enabled) begin
        check(!cfg_err_no_recovery && !cfg_err_locked && cfg_err_tlp_cpl_header == 0,
              "requester errors do not ask for a completion response");
        check(({2'd0,cfg_err_cpl_timeout} + {2'd0,cfg_err_cpl_unexpect} +
               {2'd0,cfg_err_malformed}) <= 1, "only one report per clock");
        if (cfg_err_cpl_timeout || cfg_err_cpl_unexpect || cfg_err_malformed) begin
            check(power_state == 0, "report is sampled only in D0");
            check(emitted < expected_reports, "no duplicate or unplanned report");
            case (expected_type[emitted])
                0: check(cfg_err_cpl_timeout && !cfg_err_posted, "timeout is ANFE with posted clear");
                1: check(cfg_err_cpl_unexpect && cfg_err_posted, "unexpected completion has posted set");
                2: check(cfg_err_malformed && cfg_err_posted, "malformed completion has posted set");
                default: $fatal(1, "R1_TB_FAIL unknown scoreboard kind");
            endcase
            check(cfg_err_aer_headerlog === expected_aer[emitted],
                  "AER header DWORD order and original internal tag");
            emitted++;
        end
    end

    task automatic events(
        input bit t, input bit u, input bit m, input [127:0] bad_header = MALFORMED
    );
        @(negedge clk);
        timeout_valid = t; unexpected_valid = u; malformed_valid = m;
        unexpected_header = UNEXPECTED; malformed_header = bad_header;
        @(posedge clk);
        #1;
    endtask
    task automatic idle(input int cycles = 1);
        events(0, 0, 0);
        repeat(cycles-1) @(negedge clk);
    endtask
    task automatic drain;
        idle();
        repeat(520) @(negedge clk);
        check(level == 0 && emitted == expected_reports, "all queued reports drained once");
    endtask
    task automatic reset_all;
        @(negedge clk);
        rst = 1; timeout_valid = 0; unexpected_valid = 0; malformed_valid = 0;
        power_state = 0; aer_enabled = 0; headerlog_set = 0;
        aer_uncor_mask = 0;
        repeat(2) @(negedge clk);
        check(!cfg_err_cpl_timeout && !cfg_err_cpl_unexpect && !cfg_err_malformed &&
              level == 0, "session reset masks outputs and clears queue");
        rst = 0; emitted = 0; expected_reports = 0; monitor_enabled = 1;
    endtask

    initial begin
        reset_all();
        // All three ports are handled, including synthetic RX overlap.
        expect_report(0, 0); expect_report(2, 0); expect_report(1, 0);
        events(1, 1, 1);
        drain();
        check(reported_count == 3 && !err_overflow && overflow_count == 0,
              "simultaneous sources retain every event");

        reset_all();
        // 256 entries expire over one sweep. RX can return one completion every
        // two 64-bit beats, so overlap a fresh RX error every other clock.
        for (int i = 0; i < 256; i++) begin
            expect_report(0, 0);
            if (i[0]) expect_report(1, 0);
            events(1, i[0], 0);
        end
        drain();
        check(reported_count == 384 && !err_overflow && high_water <= 130,
              "full-entry expiry burst plus legal-rate RX stays within bound");

        reset_all();
        aer_enabled = 1;
        expect_report(1, UNEXPECTED_AER);
        events(0, 1, 0);
        idle();
        // Hold the first header for an entire 512-clock window. A full timeout
        // sweep plus one RX error every other cycle uses all 512 queue entries.
        for (int i = 0; i < 512; i++) begin
            if (i < 256) expect_report(0, 0);
            if (i[0]) expect_report(1, UNEXPECTED_AER);
            events(i < 256, i[0], 0);
        end
        check(level == 512 && high_water == 512 && !err_overflow,
              "timeout sweep and legal-rate RX fit across a 512-clock AER hold");
        @(negedge clk);
        timeout_valid = 0; unexpected_valid = 0;
        headerlog_set = 1;
        drain();
        check(reported_count == 513 && !err_overflow,
              "all reports survive the delayed first ownership indication");

        reset_all();
        aer_enabled = 1;
        aer_uncor_mask = 32'h00040000; // Malformed bit 18 is masked.
        expect_report(2, MALFORMED_AER);
        events(0, 0, 1);
        idle();
        expect_report(1, UNEXPECTED_AER);
        events(0, 1, 0);
        idle(4);
        check(emitted == 2, "masked first error cannot block an unmasked later report");
        headerlog_set = 1;
        drain();

        reset_all();
        aer_enabled = 1;
        aer_uncor_mask = 32'h00054000; // Timeout, Unexpected, Malformed masks.
        expect_report(0, 0); expect_report(2, MALFORMED_AER); expect_report(1, UNEXPECTED_AER);
        events(1, 1, 1);
        drain();
        check(emitted == 3 && !headerlog_set, "masked errors report without waiting for header ownership");

        reset_all();
        aer_enabled = 1;
        expect_report(1, UNEXPECTED_AER);
        events(0, 1, 0);
        idle();
        expect_report(2, MALFORMED_AER);
        events(0, 0, 1);
        @(negedge clk);
        malformed_valid = 0;
        aer_uncor_mask[16] = 1;
        @(posedge clk);
        #1;
        check(emitted == 2 && cfg_err_aer_headerlog == MALFORMED_AER,
              "mask change releases old hold and captures the next eligible header");
        headerlog_set = 1;
        drain();

        reset_all();
        aer_enabled = 1;
        expect_report(1, UNEXPECTED_AER);
        events(0, 1, 0);
        idle();
        held_header = cfg_err_aer_headerlog;
        check(held_header == UNEXPECTED_AER, "first AER header is retained while acknowledgement is low");
        // Reports behind this first header must wait for ownership.
        events(1, 0, 1);
        @(negedge clk);
        timeout_valid = 0; malformed_valid = 0;
        repeat(4) @(negedge clk);
        check(emitted == 1 && level != 0 && cfg_err_aer_headerlog == held_header,
              "header retention prevents early metadata replacement");
        expect_report(0, 0); expect_report(2, MALFORMED_AER);
        headerlog_set = 1;
        drain();
        check(emitted == 3, "an asserted ownership level permits subsequent reports");
        @(negedge clk);
        headerlog_set = 0;
        expect_report(2, 128'h4a000002_00300008_0218b155_00000000);
        events(0, 0, 1, 128'hdeadbeef_0218b155_00300008_4a000002);
        idle(4);
        check(emitted == 4 && cfg_err_aer_headerlog == 128'h4a000002_00300008_0218b155_00000000,
              "a cleared ownership level allows a new 3DW header without logging payload");
        headerlog_set = 1;
        drain();

        // A first CTO owns an empty header, including while set is delayed.
        reset_all();
        aer_enabled = 1;
        expect_report(0, 0);
        events(1, 0, 0);
        idle();
        expect_report(2, MALFORMED_AER);
        events(0, 0, 1);
        idle(4);
        check(emitted == 1 && cfg_err_aer_headerlog == 0,
              "first CTO retains zero header until ownership is established");
        headerlog_set = 1;
        drain();

        reset_all();
        power_state = 3;
        events(1, 1, 1);
        idle();
        check(suppressed_count == 3 && reported_count == 0 && level == 0,
              "each arriving non-D0 error is counted and discarded");
        power_state = 0;
        drain();
        check(emitted == 0, "return to D0 does not report suppressed arrivals");

        // Queue contains D0 events when power changes. Discard them through
        // normal dequeue accounting and count concurrent non-D0 inputs too.
        reset_all();
        aer_enabled = 1;
        expect_report(1, UNEXPECTED_AER);
        events(0, 1, 0);
        idle();
        events(1, 0, 1);
        @(negedge clk);
        timeout_valid = 1; unexpected_valid = 1; malformed_valid = 1; power_state = 2;
        @(negedge clk);
        timeout_valid = 0; unexpected_valid = 0; malformed_valid = 0;
        idle(5);
        check(level == 0 && suppressed_count == 5 && reported_count == 1,
              "power transition accounts for queued and arriving errors once");
        headerlog_set = 1; power_state = 0;
        drain();

        // Stuck AER acknowledgement and excessive offered load have explicit
        // accounting. Old queued metadata must survive a full-queue push.
        reset_all();
        aer_enabled = 1;
        expect_report(1, UNEXPECTED_AER);
        events(0, 1, 0);
        idle();
        for (int i = 0; i < 512; i++) events(0, 0, 1);
        check(level == 512 && high_water == 512 && !err_overflow,
              "every FIFO slot is usable while AER acknowledgement is pending");
        events(1, 1, 1);
        idle();
        check(err_overflow && overflow_count == 3 && level == 512,
              "overflow counts all unaccepted events without overwriting older ones");
        for (int i = 0; i < 512; i++) expect_report(2, MALFORMED_AER);
        expect_report(0, 0);
        headerlog_set = 1;
        events(1, 1, 1);
        check(level == 512 && overflow_count == 5,
              "full queue accepts a simultaneous pop plus one new event and accounts for excess");
        drain();
        check(overflow_count == 5 && err_overflow, "overflow indication remains sticky until session abort");

        reset_all();
        aer_enabled = 1;
        expect_report(1, UNEXPECTED_AER);
        events(0, 1, 0);
        idle();
        for (int i = 0; i < 512; i++) events(0, 0, 1);
        monitor_enabled = 0;
        events(1, 1, 1);
        repeat(22000) @(negedge clk);
        timeout_valid = 0; unexpected_valid = 0; malformed_valid = 0;
        check(level == 512 && overflow_count == 16'hffff && err_overflow,
              "overflow accounting saturates while preserving the full queue");
        // Reset with pending data and an unacknowledged header.
        reset_all();
        expect_report(2, 0);
        events(0, 0, 1);
        drain();
        check(reported_count == 1 && overflow_count == 0 && !err_overflow,
              "new session reports only its own queued header");

        reset_all();
        // A power-suppression storm exercises multi-event saturating arithmetic.
        monitor_enabled = 0; power_state = 1;
        events(1, 1, 1);
        repeat(22000) @(negedge clk);
        timeout_valid = 0; unexpected_valid = 0; malformed_valid = 0;
        check(suppressed_count == 16'hffff, "suppression counter saturates without wrapping");
        reset_all();
        monitor_enabled = 0;
        events(1, 0, 0);
        repeat(65538) @(negedge clk);
        timeout_valid = 0;
        check(reported_count == 16'hffff, "reported counter saturates");
        reset_all();
        check(reported_count == 0 && suppressed_count == 0 && overflow_count == 0 &&
              !err_overflow && high_water == 0, "session abort clears queue telemetry");
        $display("R1_TB_PASS tb_req_err checks=%0d", checks);
        $finish;
    end
    initial begin
        #4000000;
        $fatal(1, "R1_TB_FAIL watchdog");
    end
endmodule
