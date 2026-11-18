// Observe the 64-bit AXI TX stream at the PCIe core in clk_pcie.
// rst is the link session abort shared by the TX stream and requester table.
`timescale 1ns / 1ps

module pcileech_req_tx_obs (
    input               clk,
    input               rst,
    input        [63:0] tx_data,
    input               tx_valid,
    input               tx_ready,
    input               tx_last,
    input               tx_err_drop,
    output              iss_valid,
    output        [7:0] iss_tag,
    output reg   [15:0] tx_drop_count
);
    reg       in_packet;
    reg       packet_read;
    reg [7:0] packet_tag;

    wire fire = tx_valid && tx_ready;
    wire first_read = tx_data[31:24] == 8'h00 || tx_data[31:24] == 8'h20;
    wire [7:0] first_tag = tx_data[47:40];

    // Present the issue at the acceptance edge so the table samples its timer
    // controls and timestamp on that edge. The table checks RESERVED ownership.
    assign iss_valid = !rst && fire && tx_last && (in_packet ? packet_read : first_read);
    assign iss_tag = in_packet ? packet_tag : first_tag;

    always @(posedge clk) begin
        if (rst) begin
            in_packet <= 1'b0;
            packet_read <= 1'b0;
            packet_tag <= 8'd0;
            tx_drop_count <= 16'd0;
        end else begin
            if (fire) begin
                in_packet <= !tx_last;
                if (!in_packet) begin
                    packet_read <= first_read;
                    packet_tag <= first_tag;
                end
            end
            // A core drop is telemetry. The tag remains owned by the table
            // until a completion, timeout, or session abort resolves it.
            if (tx_err_drop && tx_drop_count != 16'hffff)
                tx_drop_count <= tx_drop_count + 16'd1;
        end
    end

    wire _unused = &{1'b0, tx_data[63:48], tx_data[39:32], tx_data[23:0]};
endmodule
