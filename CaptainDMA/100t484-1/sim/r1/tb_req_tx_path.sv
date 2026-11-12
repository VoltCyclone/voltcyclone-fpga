// Legal TX traffic through the actual gate, board width converter and observer.
`timescale 1ns / 1ps
`include "pcileech_header.svh"

module tb_req_tx_path;
    reg clk = 0, rst = 1;
    always #8 clk = ~clk;

    IfAXIS128 input_tlps();
    IfAXIS128 gated_tlps();
    IfPCIeTlpRxTx core_tx();
    wire [255:0] free;
    wire [8:0] n_reserved, n_issued;
    wire adm_valid, iss_valid, err_bypass;
    wire [7:0] adm_tag, adm_host_tag, iss_tag;
    wire [12:0] adm_bc;
    wire [6:0] adm_la;
    wire [2:0] adm_tc;
    wire [1:0] adm_attr;
    wire [15:0] tx_drop_count;
    wire [111:0] refuse_counts;
    wire [7:0] lk_tag, lk_host_tag, up_tag;
    wire [1:0] lk_state, lk_attr;
    wire lk_superseded, up_valid, up_retire;
    wire [12:0] lk_remaining, up_remaining;
    wire [6:0] lk_next_la, up_next_la;
    wire [2:0] lk_tc;
    wire unexpected_valid, malformed_valid;
    wire [95:0] unexpected_header;
    wire [127:0] malformed_header;
    wire timeout_valid;
    wire report_timeout, report_unexpected, report_malformed, report_posted;
    wire [127:0] report_aer_header;
    wire [15:0] error_reports;
    wire error_overflow;
    wire [15:0] completed_count;
    IfPCIeTlpRxTx core_rx();
    IfAXIS128 received_tlps();
    IfAXIS128 restored_tlps();
    IfAXIS128 host_tlps();

    pcileech_req_gate_axis gate_dut (.np_cap(9'd3),
        .clk(clk), .rst(rst), .tlps_in(input_tlps), .tlps_out(gated_tlps),
        .live_rid(16'h0218), .bme(1'b1), .mrrs_code(3'd0), .ext_tag_en(1'b0),
        .free(free), .n_reserved(n_reserved), .n_issued(n_issued),
        .adm_valid(adm_valid), .adm_tag(adm_tag), .adm_host_tag(adm_host_tag),
        .adm_bc(adm_bc), .adm_la(adm_la), .adm_tc(adm_tc), .adm_attr(adm_attr),
        .admitted_count(), .refuse_counts(refuse_counts)
    );
    pcileech_tlps128_dst64 converter (
        .clk_pcie(clk), .rst(rst), .tlps_in(gated_tlps), .tlp_tx(core_tx)
    );
    pcileech_req_tx_obs observer (
        .clk(clk), .rst(rst), .tx_data(core_tx.data), .tx_valid(core_tx.valid),
        .tx_ready(core_tx.ready), .tx_last(core_tx.last), .tx_err_drop(1'b0),
        .iss_valid(iss_valid), .iss_tag(iss_tag), .tx_drop_count(tx_drop_count)
    );
    pcileech_req_table entries (
        .clk(clk), .rst(rst), .flr(1'b0), .ctl_code(4'd1), .ctl_disable(1'b1),
        .adm_valid(adm_valid), .adm_tag(adm_tag), .adm_host_tag(adm_host_tag),
        .adm_bc(adm_bc), .adm_la(adm_la), .adm_tc(adm_tc), .adm_attr(adm_attr),
        .iss_valid(iss_valid), .iss_tag(iss_tag), .rel_valid(1'b0), .rel_tag(8'd0),
        .lk_tag(lk_tag), .lk_state(lk_state), .lk_host_tag(lk_host_tag),
        .lk_superseded(lk_superseded), .lk_remaining(lk_remaining),
        .lk_next_la(lk_next_la), .lk_tc(lk_tc), .lk_attr(lk_attr),
        .up_valid(up_valid), .up_tag(up_tag), .up_retire(up_retire),
        .up_remaining(up_remaining), .up_next_la(up_next_la), .free(free),
        .to_valid(timeout_valid), .to_tag(), .n_reserved(n_reserved), .n_issued(n_issued),
        .n_quarantined(), .trn_pending(), .err_bypass(err_bypass), .err_release()
    );
    pcileech_tlps128_src64 rx_converter (
        .clk_pcie(clk), .rst(rst), .tlp_rx(core_rx), .tlps_out(received_tlps)
    );
    pcileech_req_rx_cpl rx_tracker (
        .clk(clk), .rst(rst), .flr(1'b0),
        .in_data(received_tlps.tdata), .in_keep(received_tlps.tkeepdw),
        .in_user(received_tlps.tuser), .in_last(received_tlps.tlast),
        .in_valid(received_tlps.tvalid), .out_data(restored_tlps.tdata),
        .out_keep(restored_tlps.tkeepdw), .out_user(restored_tlps.tuser),
        .out_last(restored_tlps.tlast), .out_valid(restored_tlps.tvalid),
        .lk_tag(lk_tag), .lk_state(lk_state), .lk_host_tag(lk_host_tag),
        .lk_superseded(lk_superseded), .lk_remaining(lk_remaining),
        .lk_next_la(lk_next_la), .lk_tc(lk_tc), .lk_attr(lk_attr),
        .up_valid(up_valid), .up_tag(up_tag), .up_retire(up_retire),
        .up_remaining(up_remaining), .up_next_la(up_next_la),
        .unexpected_valid(unexpected_valid), .unexpected_header(unexpected_header),
        .malformed_valid(malformed_valid), .malformed_header(malformed_header),
        .completed_count(completed_count), .unexpected_count(), .mismatch_count(),
        .bcm_count(), .crs_count(), .superseded_count(), .malformed_count()
    );
    pcileech_tlps128_filter host_filter (
        .clk_pcie(clk), .rst(rst), .alltlp_filter(1'b0), .cfgtlp_filter(1'b0),
        .tlps_in(restored_tlps), .tlps_out(host_tlps)
    );
    pcileech_req_err errors (
        .clk(clk), .rst(rst), .power_state(2'd0),
        .aer_enabled(1'b0), .aer_uncor_mask(32'd0), .headerlog_set(1'b0),
        .timeout_valid(timeout_valid), .unexpected_valid(unexpected_valid),
        .unexpected_header(unexpected_header), .malformed_valid(malformed_valid),
        .malformed_header(malformed_header),
        .cfg_err_cpl_timeout(report_timeout), .cfg_err_cpl_unexpect(report_unexpected),
        .cfg_err_malformed(report_malformed), .cfg_err_posted(report_posted),
        .cfg_err_no_recovery(), .cfg_err_locked(), .cfg_err_tlp_cpl_header(),
        .cfg_err_aer_headerlog(report_aer_header), .level(), .high_water(),
        .reported_count(error_reports), .suppressed_count(), .overflow_count(),
        .err_overflow(error_overflow)
    );

    // First reply includes an untrimmed digest on its own final 64-bit word.
    // A duplicate and an illegal 4DW completion follow the two valid replies.
    localparam logic [63:0] REPLY_WORDS[10] = '{
        64'h00200004_4a008001, 64'h11223344_02180004,
        64'h00000000_deadfeed,
        64'h00200004_4a000001, 64'h55667788_0218010c,
        64'h00200004_4a000001, 64'h11223344_02180004,
        64'h00200008_6a000002, 64'hfeed1234_0218010c,
        64'h11223344_55667788
    };
    int reply_index = 0, host_count = 0;
    int rx_unexpected_seen = 0, rx_malformed_seen = 0, reports_seen = 0;
    reg [63:0] reply_data = 0;
    reg [7:0] reply_keep = 0;
    reg reply_valid = 0, reply_last = 0;
    assign core_rx.data = reply_data;
    assign core_rx.keep = reply_keep;
    assign core_rx.valid = reply_valid;
    assign core_rx.last = reply_last;
    assign core_rx.user = 22'd0;
    always @(posedge clk) begin
        reply_valid <= !rst && cycle >= 50 && reply_index < 10;
        if (!rst && cycle >= 50 && reply_index < 10) begin
            reply_data <= REPLY_WORDS[reply_index];
            reply_keep <= reply_index == 2 ? 8'h0f : 8'hff;
            reply_last <= reply_index == 2 || reply_index == 4 ||
                          reply_index == 6 || reply_index == 9;
            reply_index <= reply_index + 1;
        end
        if (!rst && unexpected_valid) rx_unexpected_seen <= rx_unexpected_seen + 1;
        if (!rst && malformed_valid) rx_malformed_seen <= rx_malformed_seen + 1;
        if (!rst && (report_timeout || report_unexpected || report_malformed)) begin
            if (!report_posted || report_aer_header != 0 || report_timeout ||
                (reports_seen == 0 && (!report_unexpected || report_malformed)) ||
                (reports_seen == 1 && (!report_malformed || report_unexpected)) ||
                reports_seen >= 2)
                $fatal(1, "R1_TB_FAIL requester error queue reported wrong event");
            reports_seen <= reports_seen + 1;
        end
        if (!rst && host_tlps.tvalid) begin
            if (host_count >= 2 || host_tlps.tkeepdw != 4'hf ||
                !host_tlps.tlast || host_tlps.tuser[1:0] != 2'b11 ||
                host_tlps.tdata !== (host_count == 0 ?
                128'h11223344_0218b204_00200004_4a000001 :
                128'h55667788_0218d40c_00200004_4a000001))
                $fatal(1, "R1_TB_FAIL host completion %0d data=%h", host_count, host_tlps.tdata);
            host_count <= host_count + 1;
        end
    end

    // One packet per source beat. The locked read is refused between the two reads.
    localparam logic [127:0] PACKETS[4] = '{
        128'h0218560f_00001000_0218a10f_40000001,
        128'h00000000_00001004_0218b20f_00000001,
        128'h00000000_00001008_0218c30f_01000001,
        128'h0000100c_00000001_0218d40f_20000001
    };
    localparam logic [63:0] WORDS[6] = '{
        64'h0218a10f_40000001, 64'h0218560f_00001000,
        64'h0218000f_00000001, 64'h00000000_00001004,
        64'h0218010f_20000001, 64'h0000100c_00000001
    };
    int sent = 0, received = 0, cycle = 0;
    reg [127:0] source_data = 0;
    reg [3:0] source_keep = 0;
    reg source_valid = 0;
    assign input_tlps.tdata = source_data;
    assign input_tlps.tkeepdw = source_keep;
    assign input_tlps.tvalid = source_valid;
    assign input_tlps.tlast = 1'b1;
    assign input_tlps.tuser = 9'd3;
    assign input_tlps.has_data = sent < 4;
    assign core_tx.ready = cycle >= 12 && cycle % 5 < 2;

    always @(posedge clk) begin
        if (rst) begin
            sent <= 0; cycle <= 0; source_valid <= 0;
        end else begin
            cycle <= cycle + 1;
            source_valid <= input_tlps.tready && sent < 4;
            if (input_tlps.tready && sent < 4) begin
                source_data <= PACKETS[sent];
                source_keep <= (sent == 0 || sent == 3) ? 4'hf : 4'h7;
                sent <= sent + 1;
            end
        end
    end

    always @(posedge clk) if (!rst) begin
        if (err_bypass || (iss_valid && !(core_tx.valid && core_tx.ready && core_tx.last)))
            $fatal(1, "R1_TB_FAIL unexpected issue outside accepted tlast");
        if (core_tx.valid && core_tx.ready) begin
            if (received >= 6 || core_tx.data !== WORDS[received] ||
                core_tx.keep !== ((received == 3) ? 8'h0f : 8'hff) ||
                core_tx.last !== received[0])
                $fatal(1, "R1_TB_FAIL core TX word %0d data=%h keep=%h last=%b",
                       received, core_tx.data, core_tx.keep, core_tx.last);
            if (iss_valid !== (received == 3 || received == 5) ||
                (iss_valid && iss_tag !== ((received == 3) ? 8'd0 : 8'd1)))
                $fatal(1, "R1_TB_FAIL wrong issue at core TX word %0d", received);
            received <= received + 1;
        end
    end

    initial begin
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (100) @(negedge clk);
        if (received != 6 || n_issued != 0 || n_reserved != 0 || host_count != 2 ||
            completed_count != 2 || !free[0] || !free[1] ||
            rx_unexpected_seen != 1 || rx_malformed_seen != 1 ||
            reports_seen != 2 || error_reports != 2 || error_overflow ||
            err_bypass || tx_drop_count != 0 || refuse_counts[15:0] != 16'd1)
            $fatal(1, "R1_TB_FAIL wrong final TX stream or table state");
        $display("R1_TB_PASS tb_req_tx_path core_words=%0d host_completions=%0d error_reports=%0d",
                 received, host_count, reports_seen);
        $finish;
    end
endmodule
