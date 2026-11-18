//
// PCILeech FPGA.
//
// FT601 compensated clocking and PHY reset controller.
//
// The FT601 CLK pin (an MRCC pin) drives an MMCM with BUFG feedback, so c0 and
// c180 are phase-referenced to the clock at the FPGA pin:
//   c0   - CLKOUT0 at 18 degrees (0.5 ns). Input capture, protocol FSM and the
//          com clock domain. An ILOGIC register on c0 edge k captures what an
//          ideal FT601 master would sample at device edge E_k.
//   c180 - CLKOUT1 at 198 degrees (5.5 ns). Output (OLOGIC) registers only, fed
//          straight from c0 registers. The FT601 samples their value at the
//          next device edge.
//
// The reset controller runs in the free-running clk domain. phy_not_ready is
// a clk register: it rises on rst, on MMCM lock loss or input clock stop, and
// falls only after the MMCM has been reset (at least 5 ns, DS181), locked
// (up to 100 us, DS181 MMCM_TLOCKMAX) and stayed locked for STABLE_CYCLES.
// UG472 requires a reset after a lost input clock returns. The controller
// cannot see the input clock directly, so the first lock after any reset only
// proves the clock is present: it resets the MMCM once more and waits for a
// second lock before counting STABLE_CYCLES. A retry after LOCK_TIMEOUT_CYCLES
// covers a clock that is absent at reset release.
// The FT601 clock stops while the FT601 is held in reset, so lock loss is a
// normal event here and is recovered by retrying the reset/lock sequence.
// Consumers must treat c0/c180 as untrusted while phy_not_ready is high and
// assert their resets asynchronously from it.
//

`timescale 1ns / 1ps

// phy_not_ready, mmcm_rst and the synchronizers carry power-up values (not
// ready, MMCM in reset) as well as a reset, so PROCASSINIT is waived here.
/* verilator lint_off PROCASSINIT */
module pcileech_ft601_clk #(
    parameter integer RST_CYCLES          = 16,     // MMCM RST pulse, clk cycles
    parameter integer LOCK_TIMEOUT_CYCLES = 32768,  // > 100 us at 100 MHz
    parameter integer STABLE_CYCLES       = 64
) (
    input           clk,            // free-running system clock
    input           rst,            // clk-domain reset register
    input           ft601_clk,      // FT601 CLK pad (K18, MRCC)
    output          c0,
    output          c180,
    output reg      phy_not_ready = 1'b1
);

    wire clk_in;
    wire fb_raw, fb;
    wire c0_raw, c180_raw;
    wire mmcm_locked, mmcm_clkinstopped;
    reg  mmcm_rst = 1'b1;

    IBUF i_ibuf_ft601_clk ( .I ( ft601_clk ), .O ( clk_in ) );

    // Unused MMCM outputs are left open on purpose.
    /* verilator lint_off PINCONNECTEMPTY */
    MMCME2_ADV #(
        .BANDWIDTH          ( "OPTIMIZED"   ),
        .COMPENSATION       ( "ZHOLD"       ),
        .CLKIN1_PERIOD      ( 10.0          ),
        .DIVCLK_DIVIDE      ( 1             ),
        .CLKFBOUT_MULT_F    ( 10.0          ),  // VCO 1000 MHz
        .CLKFBOUT_PHASE     ( 0.0           ),
        .CLKOUT0_DIVIDE_F   ( 10.0          ),
        .CLKOUT0_PHASE      ( 18.0          ),
        .CLKOUT0_DUTY_CYCLE ( 0.5           ),
        .CLKOUT1_DIVIDE     ( 10            ),
        .CLKOUT1_PHASE      ( 198.0         ),
        .CLKOUT1_DUTY_CYCLE ( 0.5           ),
        .STARTUP_WAIT       ( "FALSE"       )
    ) i_mmcm (
        .CLKIN1             ( clk_in            ),
        .CLKIN2             ( 1'b0              ),
        .CLKINSEL           ( 1'b1              ),
        .CLKFBIN            ( fb                ),
        .CLKFBOUT           ( fb_raw            ),
        .CLKFBOUTB          (                   ),
        .CLKOUT0            ( c0_raw            ),
        .CLKOUT0B           (                   ),
        .CLKOUT1            ( c180_raw          ),
        .CLKOUT1B           (                   ),
        .CLKOUT2            (                   ),
        .CLKOUT2B           (                   ),
        .CLKOUT3            (                   ),
        .CLKOUT3B           (                   ),
        .CLKOUT4            (                   ),
        .CLKOUT5            (                   ),
        .CLKOUT6            (                   ),
        .LOCKED             ( mmcm_locked       ),
        .CLKINSTOPPED       ( mmcm_clkinstopped ),
        .CLKFBSTOPPED       (                   ),
        .RST                ( mmcm_rst          ),
        .PWRDWN             ( 1'b0              ),
        .DADDR              ( 7'h00             ),
        .DCLK               ( 1'b0              ),
        .DEN                ( 1'b0              ),
        .DI                 ( 16'h0000          ),
        .DWE                ( 1'b0              ),
        .DO                 (                   ),
        .DRDY               (                   ),
        .PSCLK              ( 1'b0              ),
        .PSEN               ( 1'b0              ),
        .PSINCDEC           ( 1'b0              ),
        .PSDONE             (                   )
    );
    /* verilator lint_on PINCONNECTEMPTY */

    BUFG i_bufg_fb   ( .I ( fb_raw   ), .O ( fb   ) );
    BUFG i_bufg_c0   ( .I ( c0_raw   ), .O ( c0   ) );
    BUFG i_bufg_c180 ( .I ( c180_raw ), .O ( c180 ) );

    // LOCKED and CLKINSTOPPED are asynchronous to clk.
    (* ASYNC_REG = "TRUE" *) reg [2:0] locked_s  = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] stopped_s = 3'b111;
    always @ ( posedge clk ) begin
        locked_s  <= {locked_s[1:0],  mmcm_locked};
        stopped_s <= {stopped_s[1:0], mmcm_clkinstopped};
    end
    wire clk_ok = locked_s[2] && !stopped_s[2];

    localparam [1:0] S_RST = 2'd0, S_LOCK = 2'd1, S_STABLE = 2'd2, S_READY = 2'd3;
    reg [1:0]  state = S_RST;
    reg [15:0] cnt   = 16'd0;
    reg        seen_lock = 1'b0;    // first lock after reset seen

    always @ ( posedge clk )
        if ( rst ) begin
            state         <= S_RST;
            cnt           <= 16'd0;
            seen_lock     <= 1'b0;
            mmcm_rst      <= 1'b1;
            phy_not_ready <= 1'b1;
        end
        else case ( state )
            S_RST: begin
                mmcm_rst      <= 1'b1;
                phy_not_ready <= 1'b1;
                cnt           <= cnt + 16'd1;
                if ( cnt == 16'(RST_CYCLES - 1) ) begin
                    state    <= S_LOCK;
                    cnt      <= 16'd0;
                    mmcm_rst <= 1'b0;
                end
            end
            S_LOCK: begin
                cnt <= cnt + 16'd1;
                if ( clk_ok && seen_lock ) begin
                    state <= S_STABLE;
                    cnt   <= 16'd0;
                end
                else if ( clk_ok ) begin            // clock present: reset again
                    seen_lock <= 1'b1;
                    state     <= S_RST;
                    cnt       <= 16'd0;
                    mmcm_rst  <= 1'b1;
                end
                else if ( cnt == 16'(LOCK_TIMEOUT_CYCLES - 1) ) begin
                    seen_lock <= 1'b0;
                    state     <= S_RST;
                    cnt       <= 16'd0;
                end
            end
            S_STABLE: begin
                cnt <= cnt + 16'd1;
                if ( !clk_ok ) begin
                    seen_lock <= 1'b0;
                    state     <= S_RST;
                    cnt       <= 16'd0;
                    mmcm_rst  <= 1'b1;
                end
                else if ( cnt == 16'(STABLE_CYCLES - 1) ) begin
                    state         <= S_READY;
                    phy_not_ready <= 1'b0;
                end
            end
            S_READY:
                if ( !clk_ok ) begin
                    seen_lock     <= 1'b0;
                    state         <= S_RST;
                    cnt           <= 16'd0;
                    mmcm_rst      <= 1'b1;
                    phy_not_ready <= 1'b1;
                end
        endcase

endmodule
/* verilator lint_on PROCASSINIT */
