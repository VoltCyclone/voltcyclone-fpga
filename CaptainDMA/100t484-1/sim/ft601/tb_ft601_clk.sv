// pcileech_ft601_clk reset controller with the MMCM model (prims_model.sv).
// Checks:
//   - phy_not_ready falls only after an MMCM reset pulse >= 5 ns whose release
//     came after the input clock was last (re)started (UG472: reset after the
//     clock returns), followed by lock;
//   - stopping the FT601 clock raises phy_not_ready within 100 ns and keeps it
//     high while stopped;
//   - rst raises phy_not_ready on the next clk edge and holds the MMCM in reset;
//   - recovery after restart, repeated.
// Pass prints FT601_CLK_PASS; failure prints FT601_CLK_FAIL.
`timescale 1ns / 1ps

module tb_ft601_clk;
    integer errors = 0;

    reg clk = 1'b0;
    always #5.0 clk = ~clk;                 // free-running system clock

    reg ft_run = 1'b0;
    reg ft_clk = 1'b0;
    always begin #5.0; if ( ft_run ) ft_clk = ~ft_clk; end

    reg  rst = 1'b1;
    wire c0, c180, phy_not_ready;

    pcileech_ft601_clk #(
        .RST_CYCLES ( 16 ), .LOCK_TIMEOUT_CYCLES ( 300 ), .STABLE_CYCLES ( 64 )
    ) dut (
        .clk ( clk ), .rst ( rst ), .ft601_clk ( ft_clk ),
        .c0 ( c0 ), .c180 ( c180 ), .phy_not_ready ( phy_not_ready ) );

    // MMCM reset pulse width and release time.
    realtime rst_rise = 0, last_rst_fall = -1, last_restart = 0;
    always @ ( posedge dut.mmcm_rst ) rst_rise = $realtime;
    always @ ( negedge dut.mmcm_rst ) begin
        last_rst_fall = $realtime;
        if ( $realtime - rst_rise < 5.0 ) begin
            errors = errors + 1;
            $display("FT601_CLK_ERR MMCM reset pulse %0.3f ns", $realtime - rst_rise);
        end
    end

    // Every ready transition must follow a reset released after the last
    // clock (re)start, with lock.
    always @ ( negedge phy_not_ready ) begin
        if ( last_rst_fall < last_restart ) begin
            errors = errors + 1;
            $display("FT601_CLK_ERR ready without MMCM reset after clock restart at %0t", $realtime);
        end
        if ( !dut.mmcm_locked || !ft_run || rst ) begin
            errors = errors + 1;
            $display("FT601_CLK_ERR ready while unlocked/stopped/reset at %0t", $realtime);
        end
        $display("FT601_CLK_INFO ready at %0t", $realtime);
    end

    task start_clock;
        begin
            last_restart = $realtime;
            ft_run = 1'b1;
        end
    endtask

    task expect_ready ( input integer max_cycles );
        integer w;
        begin
            w = 0;
            while ( phy_not_ready && w < max_cycles ) begin @( posedge clk ); w = w + 1; end
            if ( phy_not_ready ) begin
                errors = errors + 1;
                $display("FT601_CLK_ERR not ready after %0d cycles at %0t", max_cycles, $realtime);
            end
        end
    endtask

    task stop_and_check;
        realtime t0;
        begin
            #2.7;
            ft_run = 1'b0;
            t0 = $realtime;
            wait ( phy_not_ready == 1'b1 );
            if ( $realtime - t0 > 100.0 ) begin
                errors = errors + 1;
                $display("FT601_CLK_ERR clock loss took %0.1f ns to drop ready", $realtime - t0);
            end
            repeat ( 2000 ) begin
                @( posedge clk );
                if ( !phy_not_ready ) begin
                    errors = errors + 1;
                    $display("FT601_CLK_ERR ready while FT601 clock stopped at %0t", $realtime);
                end
            end
        end
    endtask

    integer it;
    initial begin
        repeat ( 5 ) @( posedge clk );
        if ( !phy_not_ready || !dut.mmcm_rst ) begin
            errors = errors + 1;
            $display("FT601_CLK_ERR not held in reset at start");
        end
        start_clock();
        @( posedge clk ); #1 rst = 1'b0;
        expect_ready(1000);

        for ( it = 0; it < 3; it = it + 1 ) begin
            stop_and_check();
            #(3.3 + it);
            start_clock();
            expect_ready(2000);
        end

        // rst while ready.
        repeat ( 50 ) @( posedge clk );
        #1 rst = 1'b1;
        @( posedge clk ); #0.1;
        if ( !phy_not_ready || !dut.mmcm_rst ) begin
            errors = errors + 1;
            $display("FT601_CLK_ERR rst did not drop ready and reset the MMCM within one cycle");
        end
        repeat ( 30 ) @( posedge clk );
        #1 rst = 1'b0;
        expect_ready(1000);

        if ( errors == 0 ) $display("FT601_CLK_PASS");
        else               $display("FT601_CLK_FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FT601_CLK_FAIL timeout");
        $finish;
    end
endmodule
