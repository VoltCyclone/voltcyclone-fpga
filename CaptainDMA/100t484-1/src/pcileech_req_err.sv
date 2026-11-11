// Serialize requester errors onto the PG054 user-error interface in clk_pcie.
// Source order for events on one edge is timeout, malformed, then unexpected.
// The reset is a link-session abort shared with the requester table.
`timescale 1ns / 1ps
module pcileech_req_err #(
    parameter integer DEPTH = 512
) (
    input clk, rst,
    input [1:0] power_state,
    input aer_enabled,
    input [31:0] aer_uncor_mask,
    input headerlog_set,
    input timeout_valid, unexpected_valid, malformed_valid,
    input [95:0] unexpected_header,
    input [127:0] malformed_header,
    output cfg_err_cpl_timeout, cfg_err_cpl_unexpect, cfg_err_malformed,
    output cfg_err_posted, cfg_err_no_recovery, cfg_err_locked,
    output [47:0] cfg_err_tlp_cpl_header,
    output [127:0] cfg_err_aer_headerlog,
    output reg [$clog2(DEPTH):0] level, high_water,
    output reg [15:0] reported_count, suppressed_count, overflow_count,
    output reg err_overflow
);
    localparam integer AW = $clog2(DEPTH);
    localparam integer CW = AW + 1;
    localparam [1:0] TIMEOUT = 2'd0, MALFORMED = 2'd1, UNEXPECTED = 2'd2;
    initial begin
        if (DEPTH < 8 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "req_err DEPTH must be a power of two and at least 8");
    end

    reg [AW-1:0] head, tail;
    reg aer_wait;
    reg [1:0] held_kind;
    reg [127:0] held_header;
    wire d0 = power_state == 2'b00;
    wire [2:0] loggable = {~aer_uncor_mask[16], ~aer_uncor_mask[18], ~aer_uncor_mask[14]};
    wire hold_header = aer_wait && aer_enabled && loggable[held_kind] && !headerlog_set;
    // Ready for UR/CA response headers does not qualify these three error types.
    // The first AER header needs retention until the level indicates ownership.
    wire pop = !rst && level != 0 && (!d0 || !hold_header);
    wire report = pop && d0;
    wire [CW:0] slots = (CW+1)'(DEPTH) - {1'b0, level} + {{CW{1'b0}}, pop};
    wire [2:0] arrivals = {2'd0,timeout_valid} + {2'd0,malformed_valid} +
                          {2'd0,unexpected_valid};

    wire [2:0] source_valid = {unexpected_valid, malformed_valid, timeout_valid};
    wire [129:0] source_data[0:2];
    assign source_data[0] = {TIMEOUT, 128'd0};
    assign source_data[1] = {MALFORMED, malformed_header};
    assign source_data[2] = {UNEXPECTED, 32'd0, unexpected_header};
    reg [2:0] wr_valid;
    reg [AW-1:0] wr_addr[0:2];
    integer accepted;
    integer source_index;
    always @* begin
        accepted = 0;
        wr_valid = 3'd0;
        for (source_index = 0; source_index < 3; source_index = source_index + 1) begin
            wr_addr[source_index] = tail + AW'(accepted);
            if (!rst && d0 && source_valid[source_index] && accepted < int'(slots)) begin
                wr_valid[source_index] = 1'b1;
                accepted = accepted + 1;
            end
        end
    end
    wire [CW-1:0] next_level = level + CW'(accepted) - {{(CW-1){1'b0}}, pop};
    wire [2:0] lost = d0 ? arrivals - 3'(accepted) : 3'd0;
    wire [2:0] suppressed = d0 ? 3'd0 : arrivals + {2'd0, pop};

    // Consecutive writes touch distinct banks. Each bank has one writer and
    // asynchronous reads, allowing distributed RAM rather than a resettable
    // multi-port flop array. Only pointers/counts reset.
    wire [129:0] bank_read[0:3];
    genvar bank;
    generate for (bank = 0; bank < 4; bank = bank + 1) begin : g_bank
        reg [129:0] memory[0:DEPTH/4-1];
        reg write_enable;
        reg [AW-3:0] write_row;
        reg [129:0] write_data;
        integer port_index;
        always @* begin
            write_enable = 1'b0;
            write_row = '0;
            write_data = '0;
            for (port_index = 0; port_index < 3; port_index = port_index + 1) begin
                if (wr_valid[port_index] && wr_addr[port_index][1:0] == 2'(bank)) begin
                    write_enable = 1'b1;
                    write_row = wr_addr[port_index][AW-1:2];
                    write_data = source_data[port_index];
                end
            end
        end
        always @(posedge clk)
            if (write_enable) memory[write_row] <= write_data;
        assign bank_read[bank] = memory[head[AW-1:2]];
    end endgenerate
    wire [129:0] entry = bank_read[head[1:0]];
    wire [1:0] kind = entry[129:128];
    wire [127:0] raw_header = entry[127:0];
    // Known 3DW headers do not log their first payload DW as header DWORD 3.
    wire three_dw = raw_header[31:29] == 3'b000 || raw_header[31:29] == 3'b010;
    wire [127:0] aer_header = {raw_header[31:0], raw_header[63:32], raw_header[95:64],
                              three_dw ? 32'd0 : raw_header[127:96]};

    assign cfg_err_cpl_timeout = report && kind == TIMEOUT;
    assign cfg_err_cpl_unexpect = report && kind == UNEXPECTED;
    assign cfg_err_malformed = report && kind == MALFORMED;
    assign cfg_err_posted = report && kind != TIMEOUT;
    assign cfg_err_no_recovery = 1'b0;
    assign cfg_err_locked = 1'b0;
    assign cfg_err_tlp_cpl_header = 48'd0;
    assign cfg_err_aer_headerlog = rst || !aer_enabled ? 128'd0 :
                                  hold_header ? held_header :
                                  report ? aer_header : 128'd0;

    function automatic [15:0] sat_add(input [15:0] count, input [2:0] amount);
        reg [16:0] sum;
        begin
            sum = {1'b0,count} + {14'd0,amount};
            sat_add = sum[16] ? 16'hffff : sum[15:0];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            head <= '0; tail <= '0; level <= '0; high_water <= '0;
            reported_count <= 16'd0;
            suppressed_count <= 16'd0;
            overflow_count <= 16'd0;
            err_overflow <= 1'b0;
            aer_wait <= 1'b0;
            held_kind <= TIMEOUT;
            held_header <= 128'd0;
        end else begin
            head <= head + AW'(pop);
            tail <= tail + AW'(accepted);
            level <= next_level;
            if (next_level > high_water) high_water <= next_level;
            reported_count <= sat_add(reported_count, {2'd0,report});
            suppressed_count <= sat_add(suppressed_count, suppressed);
            overflow_count <= sat_add(overflow_count, lost);
            if (lost != 0) err_overflow <= 1'b1;

            if (report && aer_enabled && !headerlog_set && loggable[kind]) begin
                aer_wait <= 1'b1;
                held_kind <= kind;
                held_header <= aer_header;
            end else if (!aer_enabled || headerlog_set || !loggable[held_kind]) begin
                aer_wait <= 1'b0;
            end
        end
    end
    wire _unused = &{1'b0, aer_uncor_mask[31:19], aer_uncor_mask[17],
                     aer_uncor_mask[15], aer_uncor_mask[13:0]};
endmodule
