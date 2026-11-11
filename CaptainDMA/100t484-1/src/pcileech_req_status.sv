// R1 requester status: coherent clk_pcie -> clk_sys snapshot and the
// requester block of the pcileech_fifo read-only map (contract section 9).
//
// The requester modules keep their counters in clk_pcie and reset them on the
// link-session abort. This module samples all of them on one clk_pcie edge and
// carries that word to clk_sys through xpm_cdc_handshake, so every field of a
// published snapshot comes from the same edge. Snapshots repeat continuously;
// clk_sys always holds the last delivered one. If clk_pcie stops, the sequence
// word stops advancing and the last snapshot remains readable.
//
// The handshake is never aborted (xpm_cdc_handshake has no reset and requires
// src_send to stay high until src_rcv), so the transfer FSM, the sequence and
// session-abort counters, and the clk_sys snapshot use initial values only.
//
// RO block layout, 16-bit little-endian words, byte offset from block base:
//   +00 magic/version 0x5201          +02 flags: [0] snapshot valid,
//   +04 snapshot sequence (wraps)         [1] link session abort active,
//   +06 session aborts (saturating)       [2] ERR_BYPASS, [3] ERR_RELEASE,
//   +08 RESERVED live count               [4] ERR_QUEUE_OVERFLOW
//   +0A ISSUED live count             +0C QUARANTINED live count
//   +0E admitted   +10 completed      +12 timed_out    +14 unexpected
//   +16 malformed_cpl                 +18 superseded_dropped
//   +1A CPL_MISMATCH                  +1C CPL_BCM_UNSUPPORTED
//   +1E CPL_CRS_ILLEGAL
//   +20..+2C REFUSE_ CLASS, MALFORMED, TD, RID, BME, NO_TAG, NP_CAP
//   +2E tx_err_drop
//   +30 error reports  +32 suppressed (not D0)  +34 overflow (rejected)
//   +36 error queue level             +38 error queue high water
//   +3A..+3E reserved, read 0
// Counters other than the session-abort count restart from 0 after each
// link-session abort; the session-abort count tells the host that happened.
`timescale 1ns / 1ps
module pcileech_req_status #(
    parameter integer ERR_LEVEL_W = 10
) (
    // clk_pcie
    input               clk_pcie,
    input               rst_pcie,           // link session abort (tracker reset)
    input        [15:0] admitted_count,
    input       [111:0] refuse_counts,      // REFUSE_ reasons 1..7, 16 bits each
    input         [8:0] n_reserved, n_issued, n_quarantined,
    input               timeout_valid,      // req_table to_valid
    input               err_bypass, err_release,
    input        [15:0] completed_count, unexpected_count, malformed_count,
    input        [15:0] superseded_count, mismatch_count, bcm_count, crs_count,
    input        [15:0] tx_drop_count,
    input        [15:0] err_reported_count, err_suppressed_count, err_overflow_count,
    input [ERR_LEVEL_W-1:0] err_level, err_high_water,
    input               err_overflow,
    // clk_sys
    input               clk_sys,
    output      [511:0] ro_status
);
    initial begin
        if (ERR_LEVEL_W < 1 || ERR_LEVEL_W > 16)
            $fatal(1, "req_status ERR_LEVEL_W must be 1..16");
    end
    localparam [15:0] MAGIC = 16'h5201;
    localparam integer PW = 28 * 16 - 1; // words +02..+38 less the valid flag

    function automatic [15:0] sat_inc(input [15:0] count);
        sat_inc = count == 16'hffff ? count : count + 16'd1;
    endfunction

    // ---- clk_pcie counters owned here ---------------------------------------
    reg [15:0] timed_out_count;
    initial timed_out_count = 16'd0;    // configuration value; rst_pcie also clears it
    always @(posedge clk_pcie)
        if (rst_pcie) timed_out_count <= 16'd0;
        else if (timeout_valid) timed_out_count <= sat_inc(timed_out_count);

    reg        rst_pcie_d;
    reg [15:0] session_aborts;
    initial begin rst_pcie_d = 1'b0; session_aborts = 16'd0; end
    always @(posedge clk_pcie) begin
        rst_pcie_d <= rst_pcie;
        if (rst_pcie && !rst_pcie_d) session_aborts <= sat_inc(session_aborts);
    end

    reg [15:0] snap_seq;
    initial snap_seq = 16'd0;
    wire [PW-1:0] live = {
        16'(err_high_water), 16'(err_level),
        err_overflow_count, err_suppressed_count, err_reported_count,
        tx_drop_count, refuse_counts,
        crs_count, bcm_count, mismatch_count, superseded_count, malformed_count,
        unexpected_count, timed_out_count, completed_count, admitted_count,
        7'd0, n_quarantined, 7'd0, n_issued, 7'd0, n_reserved,
        session_aborts, snap_seq,
        11'd0, err_overflow, err_release, err_bypass, rst_pcie
    };

    // ---- transfer (pattern of pcileech_pcie_cfgword_cdc) ----------------------
    localparam [1:0] S_IDLE = 2'd0, S_LOAD = 2'd1, S_SEND = 2'd2, S_DRAIN = 2'd3;
    reg [1:0]    state;
    reg          src_send;
    reg [PW-1:0] tx_word;                  // held from S_IDLE until back in S_IDLE
    initial begin state = S_IDLE; src_send = 1'b0; tx_word = {PW{1'b0}}; end
    wire         src_rcv;
    wire         dest_req;
    wire [PW-1:0] dest_out;

    always @(posedge clk_pcie) begin
        case (state)
            S_IDLE:
                if (!src_rcv) begin
                    tx_word  <= live;
                    snap_seq <= snap_seq + 16'd1;
                    state    <= S_LOAD;
                end
            S_LOAD: begin                   // tx_word stable for a clock before src_send
                src_send <= 1'b1;
                state    <= S_SEND;
            end
            S_SEND:
                if (src_rcv) begin
                    src_send <= 1'b0;
                    state    <= S_DRAIN;
                end
            S_DRAIN:                        // src_rcv must fall before the next src_send
                if (!src_rcv) state <= S_IDLE;
            default:                        // unreachable: all four encodings are states
                state <= S_IDLE;
        endcase
    end

    xpm_cdc_handshake #(
        .DEST_EXT_HSK   ( 0         ),
        .DEST_SYNC_FF   ( 4         ),
        .INIT_SYNC_FF   ( 0         ),
        .SIM_ASSERT_CHK ( 0         ),
        .SRC_SYNC_FF    ( 4         ),
        .WIDTH          ( PW        )
    ) i_xpm_cdc_handshake (
        .src_clk        ( clk_pcie  ),
        .src_in         ( tx_word   ),
        .src_send       ( src_send  ),
        .src_rcv        ( src_rcv   ),
        .dest_clk       ( clk_sys   ),
        .dest_out       ( dest_out  ),
        .dest_req       ( dest_req  ),
        .dest_ack       ( 1'b0      )
    );

    // ---- clk_sys snapshot ---------------------------------------------------
    reg [PW-1:0] snapshot;
    reg          snapshot_valid;
    initial begin snapshot = {PW{1'b0}}; snapshot_valid = 1'b0; end
    always @(posedge clk_sys)
        if (dest_req) begin
            snapshot       <= dest_out;
            snapshot_valid <= 1'b1;
        end

    assign ro_status = {48'd0, snapshot, snapshot_valid, MAGIC};
endmodule
