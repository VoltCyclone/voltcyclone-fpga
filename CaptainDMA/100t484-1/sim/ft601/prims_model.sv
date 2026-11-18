// Behavioural models of the Xilinx primitives used by the FT601 PHY, for
// Icarus Verilog only. Timing is ideal; Vivado signs off real timing.
`timescale 1ns / 1ps

module FDRE #( parameter [0:0] INIT = 1'b0 ) (
    input C, input CE, input R, input D, output reg Q );
    initial Q = INIT;
    always @ ( posedge C ) if ( R ) Q <= 1'b0; else if ( CE ) Q <= D;
endmodule

module FDPE #( parameter [0:0] INIT = 1'b1 ) (
    input C, input CE, input PRE, input D, output reg Q );
    initial Q = INIT;
    always @ ( posedge C or posedge PRE ) if ( PRE ) Q <= 1'b1; else if ( CE ) Q <= D;
endmodule

module IOBUF ( inout IO, input I, input T, output O );
    assign IO = T ? 1'bz : I;
    assign O  = IO;
endmodule

module OBUFT ( output O, input I, input T );
    assign O = T ? 1'bz : I;
endmodule

module IBUF ( input I, output O );
    assign O = I;
endmodule

module BUFG ( input I, output O );
    assign O = I;
endmodule

// Asserts dest_arst immediately; releases it DEST_SYNC_FF dest_clk edges after
// src_arst falls.
module xpm_cdc_async_rst #(
    parameter integer DEST_SYNC_FF    = 4,
    parameter integer INIT_SYNC_FF    = 0,
    parameter integer RST_ACTIVE_HIGH = 0
) ( input src_arst, input dest_clk, output dest_arst );
    wire a = RST_ACTIVE_HIGH ? src_arst : !src_arst;
    reg [DEST_SYNC_FF-1:0] s = {DEST_SYNC_FF{1'b1}};
    always @ ( posedge dest_clk or posedge a ) if ( a ) s <= {DEST_SYNC_FF{1'b1}}; else s <= s << 1;
    assign dest_arst = RST_ACTIVE_HIGH ? s[DEST_SYNC_FF-1] : !s[DEST_SYNC_FF-1];
endmodule

// MMCM model for the reset controller bench: CLKOUT0/1 follow CLKIN1 with the
// configured phase while running, LOCKED rises LOCK_EDGES input edges after RST
// falls, and CLKINSTOPPED/LOCKED react when no input edge arrives for 3 periods.
// Outputs keep toggling for a while after the input stops: the real CLKOUT
// behaviour during loss is undocumented, so the bench must not rely on it.
module MMCME2_ADV #(
    parameter BANDWIDTH = "OPTIMIZED", parameter COMPENSATION = "ZHOLD",
    parameter real CLKIN1_PERIOD = 10.0, parameter integer DIVCLK_DIVIDE = 1,
    parameter real CLKFBOUT_MULT_F = 10.0, parameter real CLKFBOUT_PHASE = 0.0,
    parameter real CLKOUT0_DIVIDE_F = 10.0, parameter real CLKOUT0_PHASE = 0.0,
    parameter real CLKOUT0_DUTY_CYCLE = 0.5, parameter integer CLKOUT1_DIVIDE = 10,
    parameter real CLKOUT1_PHASE = 0.0, parameter real CLKOUT1_DUTY_CYCLE = 0.5,
    parameter STARTUP_WAIT = "FALSE", parameter integer LOCK_EDGES = 40,
    parameter integer LOSS_LOCK_PERIODS = 30
) (
    input CLKIN1, input CLKIN2, input CLKINSEL, input CLKFBIN,
    output CLKFBOUT, output CLKFBOUTB,
    output reg CLKOUT0 = 1'b0, output CLKOUT0B, output reg CLKOUT1 = 1'b0, output CLKOUT1B,
    output CLKOUT2, output CLKOUT2B, output CLKOUT3, output CLKOUT3B,
    output CLKOUT4, output CLKOUT5, output CLKOUT6,
    output reg LOCKED = 1'b0, output reg CLKINSTOPPED = 1'b0, output CLKFBSTOPPED,
    input RST, input PWRDWN,
    input [6:0] DADDR, input DCLK, input DEN, input [15:0] DI, input DWE,
    output [15:0] DO, output DRDY,
    input PSCLK, input PSEN, input PSINCDEC, output PSDONE
);
    real    d0 = CLKOUT0_PHASE / 360.0 * CLKIN1_PERIOD;
    real    d1 = CLKOUT1_PHASE / 360.0 * CLKIN1_PERIOD;
    integer edges = 0;
    realtime last_edge = 0;
    assign CLKFBOUT = CLKIN1;
    always @ ( CLKIN1 ) begin
        CLKOUT0 <= #(d0) CLKIN1;
        CLKOUT1 <= #(d1) CLKIN1;
    end
    always @ ( posedge CLKIN1 or posedge RST )
        if ( RST ) begin
            edges  = 0;
            LOCKED <= 1'b0;
        end
        else begin
            last_edge = $realtime;
            CLKINSTOPPED <= 1'b0;
            if ( edges < LOCK_EDGES ) edges = edges + 1;
            if ( edges == LOCK_EDGES ) LOCKED <= 1'b1;
        end
    // CLKINSTOPPED after 3 missing periods; LOCKED only LOSS_LOCK_PERIODS
    // later (the real LOCKED drop latency is undocumented).
    always begin
        #(CLKIN1_PERIOD);
        if ( ($realtime - last_edge) > 3.0 * CLKIN1_PERIOD ) begin
            CLKINSTOPPED <= 1'b1;
            edges         = 0;
        end
        if ( ($realtime - last_edge) > (3.0 + LOSS_LOCK_PERIODS) * CLKIN1_PERIOD )
            LOCKED <= 1'b0;
    end
endmodule
