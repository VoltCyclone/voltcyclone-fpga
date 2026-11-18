// Proof bench for pcileech_req_cto_limits (MSIX_REQUESTER_CONTRACT.md section 8).
// Enumerates every Completion Timeout Value code for each supported user clock and
// checks, from the RTL's own outputs, that expiry can land neither before the
// window minimum nor after its maximum (B3 section 7.8.16 Table 7-25):
//   earliest expiry = (T - 1) * tick           (issue just before a tick edge)
//   latest expiry   = T * tick + tick + sweep  (sweep visits 256 entries, 1/cycle)
// plus the 0.9 * max target (rounded up), the drain interval Q >= window max, and
// Disable -> Q = 64 s. Prints R1_TB_PASS on success.
`timescale 1ns / 1ps

module tb_req_cto_limits;
    localparam int W = $bits(u62.t_ticks);   // the module's default width
    integer errors = 0, checks = 0;

    // Table 7-25 windows in ps; reserved/unadvertised codes use the 0000b row.
    function automatic longint win_min(input [3:0] c);
        case (c)
            4'b0001: win_min = 64'd50_000_000;
            4'b0010: win_min = 64'd1_000_000_000;
            4'b0101: win_min = 64'd16_000_000_000;
            4'b0110: win_min = 64'd65_000_000_000;
            4'b1001: win_min = 64'd260_000_000_000;
            4'b1010: win_min = 64'd1_000_000_000_000;
            4'b1101: win_min = 64'd4_000_000_000_000;
            4'b1110: win_min = 64'd17_000_000_000_000;
            default: win_min = 64'd50_000_000;           // 0000b: 50 us
        endcase
    endfunction
    function automatic longint win_max(input [3:0] c);
        case (c)
            4'b0001: win_max = 64'd100_000_000;
            4'b0010: win_max = 64'd10_000_000_000;
            4'b0101: win_max = 64'd55_000_000_000;
            4'b0110: win_max = 64'd210_000_000_000;
            4'b1001: win_max = 64'd900_000_000_000;
            4'b1010: win_max = 64'd3_500_000_000_000;
            4'b1101: win_max = 64'd13_000_000_000_000;
            4'b1110: win_max = 64'd64_000_000_000_000;
            default: win_max = 64'd50_000_000_000;       // 0000b: 50 ms
        endcase
    endfunction

    reg  [3:0]   code;
    reg          dis;
    wire [W-1:0] t62, q62, t125, q125;
    pcileech_req_cto_limits #(.CLK_PCIE_HZ(62_500_000), .TICK_CYCLES(64))
        u62 (.code(code), .disable_lat(dis), .t_ticks(t62), .q_ticks(q62));
    pcileech_req_cto_limits #(.CLK_PCIE_HZ(125_000_000), .TICK_CYCLES(64))
        u125 (.code(code), .disable_lat(dis), .t_ticks(t125), .q_ticks(q125));

    // 64 s at 125 MHz / 64-cycle ticks (512 ns): the largest limit any instance holds.
    localparam longint QDIS125 = 64'd125_000_000;

    task check_clock;
        input [8*8-1:0] name; input longint clk_ps; input longint t; input longint q;
        longint tick, sweep, earliest, latest, mn, mx;
        begin
            tick = clk_ps * 64; sweep = clk_ps * 256;
            mn = win_min(code); mx = win_max(code);
            earliest = (t - 1) * tick;
            latest   = t * tick + tick + sweep;
            checks = checks + 4;
            if (!(earliest > mn)) begin errors++;
                $display("R1_TB_FAIL %0s code=%b earliest %0d ps <= min %0d", name, code, earliest, mn); end
            if (!(latest < mx)) begin errors++;
                $display("R1_TB_FAIL %0s code=%b latest %0d ps >= max %0d", name, code, latest, mx); end
            if (!(t * tick * 10 >= mx * 9 && (t - 1) * tick * 10 < mx * 9)) begin errors++;
                $display("R1_TB_FAIL %0s code=%b T=%0d ticks is not 0.9*max rounded up", name, code, t); end
            if (!(q * tick >= mx && (q - 1) * tick < mx)) begin errors++;
                $display("R1_TB_FAIL %0s code=%b Q=%0d ticks is not window max rounded up", name, code, q); end
        end
    endtask

    initial begin
        dis = 0;
        for (int c = 0; c < 16; c++) begin
            code = c[3:0]; #1;
            check_clock("62.5MHz", 64'd16_000, t62, q62);
            check_clock("125MHz",  64'd8_000,  t125, q125);
        end
        // Disable latched: drain is the largest defined window, 64 s.
        dis = 1;
        for (int c = 0; c < 16; c++) begin
            code = c[3:0]; #1;
            checks = checks + 2;
            if (q62 * 64'd1_024_000 < 64'd64_000_000_000_000 || (q62 - 1) * 64'd1_024_000 >= 64'd64_000_000_000_000) begin
                errors++; $display("R1_TB_FAIL 62.5MHz disable code=%b Q=%0d is not 64 s", code, q62); end
            if (q125 * 64'd512_000 < 64'd64_000_000_000_000 || (q125 - 1) * 64'd512_000 >= 64'd64_000_000_000_000) begin
                errors++; $display("R1_TB_FAIL 125MHz disable code=%b Q=%0d is not 64 s", code, q125); end
        end
        // Width: the modular counter must exceed every limit.
        checks = checks + 1;
        if (64'(q125) >= (64'd1 << (W - 1)) || 64'(q125) != QDIS125) begin
            errors++; $display("R1_TB_FAIL W=%0d leaves no modular margin for Q=%0d", W, q125); end

        if (errors == 0) $display("R1_TB_PASS tb_req_cto_limits checks=%0d", checks);
        else             $display("R1_TB_FAILED tb_req_cto_limits errors=%0d checks=%0d", errors, checks);
        $finish;
    end
endmodule
