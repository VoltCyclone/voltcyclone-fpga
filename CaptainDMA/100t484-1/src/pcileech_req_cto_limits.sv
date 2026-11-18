//
// PCILeech FPGA.
//
// R1 requester tracking: Completion Timeout code -> timer limits.
// Contract: PCILeechFWGenerator docs/development/MSIX_REQUESTER_CONTRACT.md section 8.
//
// Windows are PCIe Base 3.0 section 7.8.16 Table 7-25. The expiry target is
// T = 0.9 x window max, rounded up to whole ticks; the drain interval after a timeout
// or FLR is the window max rounded up, or 64 s when Disable was latched. Reserved and
// unadvertised encodings use the 0000b row (an implementation choice; B3 defines no
// hardware behaviour for them). Every arm is a constant expression, so synthesis
// folds this to a small ROM. tb_req_cto_limits proves the margins for each code.
//
`timescale 1ns / 1ps

module pcileech_req_cto_limits #(
    parameter longint CLK_PCIE_HZ = 62_500_000,
    parameter int     TICK_CYCLES = 64,
    parameter int     W           = 28
) (
    input  [3:0]    code,           // cfg_dcommand2[3:0], latched at ISSUED
    input           disable_lat,    // Completion Timeout Disable latched at ISSUED
    output [W-1:0]  t_ticks,        // expire when elapsed >= t_ticks
    output [W-1:0]  q_ticks         // drain interval after a timeout or FLR
);
    localparam longint PS_PER_S = 64'd1_000_000_000_000;
    localparam longint TICK_PS  = (TICK_CYCLES * PS_PER_S) / CLK_PCIE_HZ;

    initial if ((TICK_CYCLES * PS_PER_S) % CLK_PCIE_HZ != 0)
        $fatal(1, "pcileech_req_cto_limits: tick period is not a whole number of ps");

    function automatic longint ceil_ticks(input longint ps);
        ceil_ticks = (ps + TICK_PS - 1) / TICK_PS;
    endfunction

    // {T, Q} per code; window max in ps is written out in each arm.
    localparam longint T0000 = ceil_ticks(64'd45_000_000_000),     Q0000 = ceil_ticks(64'd50_000_000_000);
    localparam longint T0001 = ceil_ticks(64'd90_000_000),         Q0001 = ceil_ticks(64'd100_000_000);
    localparam longint T0010 = ceil_ticks(64'd9_000_000_000),      Q0010 = ceil_ticks(64'd10_000_000_000);
    localparam longint T0101 = ceil_ticks(64'd49_500_000_000),     Q0101 = ceil_ticks(64'd55_000_000_000);
    localparam longint T0110 = ceil_ticks(64'd189_000_000_000),    Q0110 = ceil_ticks(64'd210_000_000_000);
    localparam longint T1001 = ceil_ticks(64'd810_000_000_000),    Q1001 = ceil_ticks(64'd900_000_000_000);
    localparam longint T1010 = ceil_ticks(64'd3_150_000_000_000),  Q1010 = ceil_ticks(64'd3_500_000_000_000);
    localparam longint T1101 = ceil_ticks(64'd11_700_000_000_000), Q1101 = ceil_ticks(64'd13_000_000_000_000);
    localparam longint T1110 = ceil_ticks(64'd57_600_000_000_000), Q1110 = ceil_ticks(64'd64_000_000_000_000);
    localparam longint QDIS  = Q1110;                               // 64 s

    // The modular elapsed counter needs one spare bit above the largest limit.
    initial if (QDIS >= (64'd1 << (W - 1)))
        $fatal(1, "pcileech_req_cto_limits: W=%0d cannot hold Q=%0d ticks", W, QDIS);

    reg [W-1:0] t, q;
    always @* begin
        case (code)
            4'b0001: begin t = T0001[W-1:0]; q = Q0001[W-1:0]; end
            4'b0010: begin t = T0010[W-1:0]; q = Q0010[W-1:0]; end
            4'b0101: begin t = T0101[W-1:0]; q = Q0101[W-1:0]; end
            4'b0110: begin t = T0110[W-1:0]; q = Q0110[W-1:0]; end
            4'b1001: begin t = T1001[W-1:0]; q = Q1001[W-1:0]; end
            4'b1010: begin t = T1010[W-1:0]; q = Q1010[W-1:0]; end
            4'b1101: begin t = T1101[W-1:0]; q = Q1101[W-1:0]; end
            4'b1110: begin t = T1110[W-1:0]; q = Q1110[W-1:0]; end
            default: begin t = T0000[W-1:0]; q = Q0000[W-1:0]; end
        endcase
        if (disable_lat) q = QDIS[W-1:0];
    end
    assign t_ticks = t;
    assign q_ticks = q;
endmodule
