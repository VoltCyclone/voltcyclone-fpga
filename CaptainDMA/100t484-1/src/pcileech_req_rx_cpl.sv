// Match completions on the always-ready 128-bit stream from src64.
// The PCIe core validates the received packet's payload/digest framing and RID.
// Lookup/update use the header edge so a final completion can beat a due sweep.
`timescale 1ns / 1ps
`include "pcileech_req_defs.svh"

module pcileech_req_rx_cpl (
    input clk, rst, flr,
    input [127:0] in_data,
    input [3:0] in_keep,
    input [8:0] in_user,
    input in_last, in_valid,
    output reg [127:0] out_data,
    output reg [3:0] out_keep,
    output reg [8:0] out_user,
    output reg out_last, out_valid,

    output [7:0] lk_tag,
    input [1:0] lk_state,
    input [7:0] lk_host_tag,
    input lk_superseded,
    input [12:0] lk_remaining,
    input [6:0] lk_next_la,
    input [2:0] lk_tc,
    input [1:0] lk_attr,
    output [7:0] up_tag,
    output reg up_valid, up_retire,
    output [12:0] up_remaining,
    output [6:0] up_next_la,

    output reg unexpected_valid,
    output [95:0] unexpected_header,
    output reg malformed_valid,
    output [127:0] malformed_header,
    output reg [15:0] completed_count, unexpected_count, mismatch_count,
    output reg [15:0] bcm_count, crs_count, superseded_count, malformed_count
);
    reg in_packet, pass_packet, strip_packet;
    reg [10:0] body_left;
    wire first = !in_packet && in_user[0];
    wire [4:0] typ = in_data[28:24];
    wire [2:0] fmt = in_data[31:29];
    wire locked = typ == 5'h0b;
    wire cpl = locked || typ == 5'h0a;
    wire format_ok = fmt == 3'b000 || fmt == 3'b010;
    wire has_data = in_data[30];
    wire td = in_data[15];
    wire [2:0] status = in_data[47:45];
    wire success = status == 3'd0;
    wire bcm = in_data[44];
    wire [6:0] lower_addr = in_data[70:64];
    wire [11:0] bc_field = in_data[43:32];
    wire [9:0] length_field = in_data[9:0];
    wire [12:0] byte_count = bc_field == 0 ? 13'd4096 : {1'b0, bc_field};
    wire [10:0] length_dw = length_field == 0 ? 11'd1024 : {1'b0, length_field};
    wire [12:0] capacity = {length_dw, 2'b00} - {11'd0, lower_addr[1:0]};
    wire [10:0] body_words = has_data ? 11'd3 + length_dw : 11'd3;
    wire [10:0] wire_words = body_words + {10'd0, td};

    function automatic [3:0] keep_for_words(input [10:0] words);
        case (words)
            0: keep_for_words = 4'h0;
            1: keep_for_words = 4'h1;
            2: keep_for_words = 4'h3;
            3: keep_for_words = 4'h7;
            default: keep_for_words = 4'hf;
        endcase
    endfunction

    wire shape_ok = in_keep == keep_for_words(wire_words) &&
                    in_last == (wire_words <= 11'd4);
    wire class_match = in_data[22:20] == lk_tc && in_data[13:12] == lk_attr;
    wire progress_match = byte_count == lk_remaining && lower_addr == lk_next_la;
    // A final data completion may have up to three trailing padding bytes.
    wire final_data = byte_count <= capacity;
    wire length_ok = !final_data || capacity - byte_count <= 13'd3;
    wire issued = lk_state == `REQ_ST_ISSUED;
    wire quarantined = lk_state == `REQ_ST_QUARANTINED;

    assign lk_tag = in_data[79:72];
    assign up_tag = lk_tag;
    assign up_remaining = up_retire ? 13'd0 : lk_remaining - capacity;
    assign up_next_la = lower_addr + capacity[6:0];
    assign unexpected_header = in_data[95:0];
    assign malformed_header = in_data;

    reg pass_first, mismatch, count_bcm, count_crs, count_superseded;
    always @* begin
        pass_first = first;
        up_valid = 1'b0;
        up_retire = 1'b0;
        unexpected_valid = 1'b0;
        malformed_valid = 1'b0;
        mismatch = 1'b0;
        count_bcm = 1'b0;
        count_crs = 1'b0;
        count_superseded = 1'b0;
        if (!rst && in_valid && first && cpl) begin
            pass_first = 1'b0;
            if (!format_ok || !shape_ok) begin
                malformed_valid = 1'b1;
            end else if (!issued && !quarantined) begin
                unexpected_valid = 1'b1;
            end else if (locked || success != has_data) begin
                unexpected_valid = 1'b1;
                mismatch = 1'b1;
            end else if (success && bcm) begin
                count_bcm = 1'b1;
                unexpected_valid = quarantined;
            end else if (!class_match || (success && (!progress_match || !length_ok))) begin
                unexpected_valid = 1'b1;
                mismatch = 1'b1;
            end else begin
                up_valid = 1'b1;
                up_retire = !success || final_data;
                if (status == 3'd2) begin
                    count_crs = 1'b1;
                    unexpected_valid = quarantined;
                end else if (quarantined || (flr && !up_retire)) begin
                    unexpected_valid = 1'b1;
                end else if (lk_superseded) begin
                    count_superseded = 1'b1;
                end else begin
                    pass_first = 1'b1;
                end
            end
        end
    end

    // With IP digest trimming enabled TD is already clear. With trimming off,
    // the header Length identifies the last body word before the digest. This
    // also closes tlast correctly when the digest occupies its own input beat.
    wire pass_beat = first ? pass_first : pass_packet;
    wire strip = first ? pass_first && cpl && td : strip_packet;
    wire [10:0] words_left = first ? body_words : body_left;
    wire emit_last = strip ? words_left <= 11'd4 : in_last;
    reg [127:0] restored;
    always @* begin
        restored = in_data;
        if (first && cpl && pass_first) begin
            restored[79:72] = lk_host_tag;
            restored[15] = 1'b0;
        end
    end

    function automatic [15:0] sat_inc(input [15:0] count);
        sat_inc = count == 16'hffff ? count : count + 16'd1;
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            in_packet <= 1'b0;
            pass_packet <= 1'b0;
            strip_packet <= 1'b0;
            body_left <= 11'd0;
            out_valid <= 1'b0;
            completed_count <= 16'd0;
            unexpected_count <= 16'd0;
            mismatch_count <= 16'd0;
            bcm_count <= 16'd0;
            crs_count <= 16'd0;
            superseded_count <= 16'd0;
            malformed_count <= 16'd0;
        end else begin
            out_valid <= in_valid && pass_beat && (!strip || words_left != 0);
            if (in_valid) begin
                in_packet <= !in_last;
                if (first || in_last) begin
                    pass_packet <= !in_last && pass_first;
                    strip_packet <= !in_last && strip;
                end
                if (strip)
                    body_left <= words_left > 11'd4 ? words_left - 11'd4 : 11'd0;
                out_data <= restored;
                out_keep <= strip ? in_keep & keep_for_words(words_left) : in_keep;
                out_last <= emit_last;
                out_user <= strip ? {in_user[8:2], emit_last, in_user[0]} : in_user;
            end
            if (up_valid && up_retire && issued) completed_count <= sat_inc(completed_count);
            if (unexpected_valid) unexpected_count <= sat_inc(unexpected_count);
            if (mismatch) mismatch_count <= sat_inc(mismatch_count);
            if (count_bcm) bcm_count <= sat_inc(bcm_count);
            if (count_crs) crs_count <= sat_inc(crs_count);
            if (count_superseded) superseded_count <= sat_inc(superseded_count);
            if (malformed_valid) malformed_count <= sat_inc(malformed_count);
        end
    end
endmodule
