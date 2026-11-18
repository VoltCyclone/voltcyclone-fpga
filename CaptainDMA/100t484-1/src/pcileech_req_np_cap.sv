// R1: sample advertised NP header credit exactly once per link session.
// PG054 "Flow Control Credit Information": initial credits are available at
// user_lnk_up; fc_sel takes two user clocks to appear at fc_*.
// Tie the core selector to 101 (transmit credit LIMIT), not 100 (signed space).
// Before this sample every outgoing NP source must be behind the closed gate.
// Later LIMIT values are cumulative UpdateFC counts and MUST NOT be resampled.
`timescale 1ns / 1ps
module pcileech_req_np_cap (
    input clk, rst, link_up,       // rst is session abort, NEVER rst_subsys/FLR
    input [7:0] fc_nph,
    output [8:0] np_cap
);
    reg [1:0] up_delay;
    reg sampled;
    reg [8:0] cap;
    initial begin up_delay = 2'b00; sampled = 1'b0; cap = 9'd0; end
    assign np_cap = (rst || !link_up) ? 9'd0 : cap;
    always @(posedge clk) begin
        if (rst || !link_up) begin
            up_delay <= 2'b00;
            sampled <= 1'b0;
            cap <= 9'd0;
        end else begin
            up_delay <= {up_delay[0], 1'b1};
            if (up_delay[1] && !sampled) begin
                // Both binary parity values mean every credit bit is known.
                // The default keeps a 4-state unknown credit fail-closed and
                // permits retry once the core presents a definite value.
                case (^fc_nph)
                    1'b0, 1'b1: begin
                        sampled <= 1'b1;
                        // Zero denotes infinite credit; C=1 is conservative.
                        if (fc_nph == 8'd0) cap <= 9'd35;
                        else if (fc_nph >= 8'd8) cap <= 9'd256;
                        else cap <= {1'b0, fc_nph} * 9'd35;
                    end
                    default: cap <= 9'd0;
                endcase
            end
        end
    end
endmodule
