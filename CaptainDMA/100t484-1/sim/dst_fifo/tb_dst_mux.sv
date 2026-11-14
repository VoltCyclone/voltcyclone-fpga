// SYS-side prefetch in pcileech_tlps128_dst_fifo: lockstep against the frozen
// reference (dst_fifo_reference.sv, board e210d72), each driving a real
// pcileech_mux, with the real fifo_134_134_clk2 and reset-window modules.
//
// Both designs see the same PCIe RX stream, reset pulses and mux rd_en. The
// write side is unchanged, so the beats written into each FIFO must be
// identical; that is checked on clk_pcie. On clk_sys each mux output word is
// decoded back into DWs (filler tag 2'b11 skipped) and checked against that
// design's own written stream:
//   - DWs arrive in written order with the written first/last flags;
//   - a written DW may be skipped only if a reset intervened (its epoch is
//     older than the next delivered DW), and no stale-epoch DW is delivered
//     once the read side is accessible again;
//   - without resets, nothing is skipped and both designs deliver everything;
//   - pull contract: a dfifo lane is valid only in the cycle after rx_rd_en
//     (pcileech_mux writes only then);
//   - drain throughput from a preloaded FIFO: prefetch <= reference + 4.
// PASS marker: DST_MUX_PASS.
`timescale 1ns / 1ps
`include "pcileech_header.svh"
module tb_dst_mux;
    parameter real PCIE_HALF = 8.0;    // 62.5 MHz
    parameter real SYS_HALF  = 5.0;    // 100 MHz
    parameter integer SEED   = 1;

    integer rng = SEED;
    function automatic integer rnd(input integer n);
        rnd = ($random(rng) & 32'h7fffffff) % n;
    endfunction

    reg clk_pcie = 0, clk_sys = 0;
    always #(PCIE_HALF) clk_pcie = ~clk_pcie;
    initial begin #(SYS_HALF * 0.37); forever #(SYS_HALF) clk_sys = ~clk_sys; end

    reg rst = 1'b1;            // clk_sys register, as rst_subsys_sys
    reg mrst = 1'b1;           // mux reset: initial only
    reg mux_rd = 1'b0;         // consumer ready (com_din_ready)
    integer rd_pct = 70;
    reg [3:0] epoch = 0;       // incremented on every reset assertion

    // ---------------- PCIe RX source (cannot be stalled) ----------------
    IfAXIS128 rx();
    reg [127:0] s_data = 0;
    reg [3:0]   s_keep = 0;
    reg         s_valid = 0, s_last = 0, s_first = 0;
    assign rx.tdata = s_data; assign rx.tkeepdw = s_keep; assign rx.tvalid = s_valid;
    assign rx.tlast = s_last; assign rx.tuser = {8'b0, s_first};

    reg [27:0] seq = 0;        // global DW sequence
    integer    pkt_left = 0;   // DWs left in current packet
    integer    gap_pct = 30;
    reg        src_on = 1'b0;
    always @ ( posedge clk_pcie ) begin
        s_valid <= 1'b0;
        if ( src_on && rnd(100) >= gap_pct ) begin : beat
            integer n, k;
            reg first;
            first = (pkt_left == 0);
            if ( first )
                pkt_left = 1 + rnd(12);
            n = pkt_left > 4 ? 4 : pkt_left;
            for ( k = 0; k < 4; k = k + 1 )
                s_data[32*k +: 32] <= (k < n) ? {epoch, seq + k[27:0]} : 32'h0;
            s_keep  <= (n == 4) ? 4'b1111 : (n == 3) ? 4'b0111 : (n == 2) ? 4'b0011 : 4'b0001;
            s_first <= first;
            s_last  <= (pkt_left == n);
            s_valid <= 1'b1;
            seq      = seq + n;
            pkt_left = pkt_left - n;
        end
    end

    // ---------------- DUTs ----------------
    IfPCIeFifoTlp df[2]();
    pcileech_tlps128_dst_fifo_ref i_ref (.rst(rst), .clk_pcie(clk_pcie), .clk_sys(clk_sys), .tlps_in(rx), .dfifo(df[0]));
    pcileech_tlps128_dst_fifo     i_new (.rst(rst), .clk_pcie(clk_pcie), .clk_sys(clk_sys), .tlps_in(rx), .dfifo(df[1]));

    wire [255:0] mdout[2];
    wire         mvalid[2];
    genvar g;
    generate for ( g = 0; g < 2; g = g + 1 ) begin : gm
        pcileech_mux i_mux(
            .clk(clk_sys), .rst(mrst), .dout(mdout[g]), .valid(mvalid[g]), .rd_en(mux_rd),
            .p0_din(32'h0), .p0_tag(2'b10), .p0_ctx(2'b00), .p0_wr_en(1'b0), .p0_req_data(),
            .p1_din(32'h0), .p1_tag(2'b01), .p1_ctx(2'b00), .p1_wr_en(1'b0), .p1_req_data(),
            .p2_din(32'h0), .p2_tag(2'b01), .p2_ctx(2'b00), .p2_wr_en(1'b0), .p2_req_data(),
            .p3_din(df[g].rx_data[0]), .p3_tag(2'b00), .p3_ctx({df[g].rx_first[0], df[g].rx_last[0]}), .p3_wr_en(df[g].rx_valid[0]), .p3_req_data(df[g].rx_rd_en),
            .p4_din(df[g].rx_data[1]), .p4_tag(2'b00), .p4_ctx({df[g].rx_first[1], df[g].rx_last[1]}), .p4_wr_en(df[g].rx_valid[1]), .p4_req_data(),
            .p5_din(df[g].rx_data[2]), .p5_tag(2'b00), .p5_ctx({df[g].rx_first[2], df[g].rx_last[2]}), .p5_wr_en(df[g].rx_valid[2]), .p5_req_data(),
            .p6_din(df[g].rx_data[3]), .p6_tag(2'b00), .p6_ctx({df[g].rx_first[3], df[g].rx_last[3]}), .p6_wr_en(df[g].rx_valid[3]), .p6_req_data(),
            .p7_din(32'h0), .p7_tag(2'b11), .p7_ctx(2'b00), .p7_wr_en(1'b0), .p7_req_data()
        );
    end endgenerate
    // plain copies of the dfifo ports (interface arrays need constant indices)
    wire [3:0]  rxv [2];
    wire [31:0] rxd [2][4];
    wire        rxrd [2];
    generate for ( g = 0; g < 2; g = g + 1 ) begin : gc
        assign rxv[g]  = { df[g].rx_valid[3], df[g].rx_valid[2], df[g].rx_valid[1], df[g].rx_valid[0] };
        assign rxd[g][0] = df[g].rx_data[0]; assign rxd[g][1] = df[g].rx_data[1];
        assign rxd[g][2] = df[g].rx_data[2]; assign rxd[g][3] = df[g].rx_data[3];
        assign rxrd[g] = df[g].rx_rd_en;
    end endgenerate
    assign df[0].tx_data = 0; assign df[0].tx_last = 0; assign df[0].tx_valid = 0;
    assign df[1].tx_data = 0; assign df[1].tx_last = 0; assign df[1].tx_valid = 0;

    // ---------------- written streams (clk_pcie) ----------------
    localparam integer QN = 1 << 20;
    reg [33:0] wq [2][QN];     // {first, last, dw}
    integer    wn [2] = '{0, 0};
    integer    rp [2] = '{0, 0};
    integer    errors = 0;
    wire       wen [2];
    wire [133:0] wdin [2];
    assign wen[0] = i_ref.i_fifo_134_134_clk2.wr_en;  assign wdin[0] = i_ref.i_fifo_134_134_clk2.din;
    assign wen[1] = i_new.i_fifo_134_134_clk2.wr_en;  assign wdin[1] = i_new.i_fifo_134_134_clk2.din;
    always @ ( posedge clk_pcie ) begin : wlog
        integer d, k;
        if ( wen[0] !== wen[1] || (wen[0] && wdin[0] !== wdin[1]) ) begin
            $display("DST_WRITE_MISMATCH t=%0t", $time); errors = errors + 1;
        end
        for ( d = 0; d < 2; d = d + 1 )
            if ( wen[d] ) begin : wr
                integer top;
                top = wdin[d][131] ? 3 : wdin[d][130] ? 2 : wdin[d][129] ? 1 : 0;
                for ( k = 0; k <= top; k = k + 1 ) begin
                    wq[d][wn[d]] = { wdin[d][133] && (k == 0), wdin[d][132] && (k == top), wdin[d][32*k +: 32] };
                    wn[d] = wn[d] + 1;
                end
            end
    end

    // ---------------- delivered streams (clk_sys) ----------------
    // Primary: the dfifo -> mux boundary. A lane is accepted when the mux's
    // write enable `en` (rd_en delayed one cycle) is high.
    // Secondary: the mux output, decoded back into DWs, must match the
    // accepted stream exactly in every phase, and valid must never be high
    // while rd_en is low. (The stock mux, before its output-queue fix, lost or
    // repeated words around rd_en transitions; with OUT_EXACT=0 such anomalies
    // are classified as mux_drop/mux_rep instead of failing, for comparison.)
    integer delivered [2] = '{0, 0};
    integer skipped   [2] = '{0, 0};
    integer last_skip [2] = '{-1, -1};   // index of the last skipped written DW
    integer mux_drop  [2] = '{0, 0};
    integer mux_rep   [2] = '{0, 0};
    parameter integer OUT_EXACT = 1;
    reg     out_exact = OUT_EXACT;
    integer an [2] = '{0, 0};      // accepted DWs
    integer op [2] = '{0, 0};      // mux-output pointer into accepted DWs
    reg [33:0] aq [2][QN];
    reg     rd_q [2] = '{0, 0};
    reg [3:0] flushed [2] = '{0, 0};   // epoch at this design's last read-side flush
    wire    acc [2];
    wire    men [2];
    assign acc[0] = i_ref.acc_sys;
    assign acc[1] = i_new.acc_sys;
    assign men[0] = gm[0].i_mux.en;
    assign men[1] = gm[1].i_mux.en;
    always @ ( posedge clk_sys ) begin : rlog
        integer d, l, s;
        reg [33:0] e;
        reg [3:0]  cx;
        reg [31:0] dw;
        for ( d = 0; d < 2; d = d + 1 ) begin
            if ( mvalid[d] && !mux_rd ) begin
                $display("DST_MUX_VALID_NOT_READY d=%0d t=%0t", d, $time); errors = errors + 1;
            end
            // pull contract
            if ( rxv[d] != 4'b0 && !rd_q[d] ) begin
                $display("DST_PULL_CONTRACT d=%0d t=%0t", d, $time); errors = errors + 1;
            end
            rd_q[d] = rxrd[d];
            // no beat older than this design's last read-side flush
            if ( !acc[d] ) flushed[d] = epoch;
            for ( l = 0; l < 4; l = l + 1 )
                if ( rxv[d][l] ) begin
                    if ( rxd[d][l][31:28] != flushed[d] ) begin
                        $display("DST_STALE d=%0d t=%0t dw=%h flushed=%0d", d, $time, rxd[d][l], flushed[d]);
                        errors = errors + 1;
                    end
                    if ( men[d] ) begin
                        e = { df_first(d, l), df_last(d, l), rxd[d][l] };
                        aq[d][an[d]] = e; an[d] = an[d] + 1;
                        // skip written DWs only across a reset (older epoch)
                        while ( rp[d] < wn[d] && wq[d][rp[d]][31:0] !== e[31:0] && wq[d][rp[d]][31:28] !== e[31:28] ) begin
                            last_skip[d] = rp[d]; rp[d] = rp[d] + 1; skipped[d] = skipped[d] + 1;
                        end
                        if ( rp[d] >= wn[d] || wq[d][rp[d]] !== e ) begin
                            $display("DST_ORDER d=%0d t=%0t got=%h exp=%h", d, $time, e,
                                     rp[d] < wn[d] ? wq[d][rp[d]] : 34'h0);
                            errors = errors + 1;
                        end
                        else
                            rp[d] = rp[d] + 1;
                        delivered[d] = delivered[d] + 1;
                    end
                end
            // mux output
            if ( mvalid[d] )
                for ( s = 0; s < 7; s = s + 1 ) begin
                    case ( s )
                        0: cx = mdout[d][251:248]; 1: cx = mdout[d][255:252];
                        2: cx = mdout[d][243:240]; 3: cx = mdout[d][247:244];
                        4: cx = mdout[d][235:232]; 5: cx = mdout[d][239:236];
                        default: cx = mdout[d][227:224];
                    endcase
                    dw = mdout[d][223 - 32*s -: 32];
                    if ( cx[1:0] == 2'b00 ) begin : outdw
                        integer f, j;
                        if ( op[d] < an[d] && aq[d][op[d]] === {cx[3], cx[2], dw} )
                            op[d] = op[d] + 1;
                        else if ( out_exact ) begin
                            $display("DST_MUX_ORDER d=%0d t=%0t got=%h/%b", d, $time, dw, cx[3:2]);
                            errors = errors + 1;
                        end
                        else begin
                            f = -1;
                            for ( j = op[d]; j < an[d] && f < 0; j = j + 1 )
                                if ( aq[d][j] === {cx[3], cx[2], dw} ) f = j;
                            if ( f >= 0 ) begin
                                mux_drop[d] = mux_drop[d] + (f - op[d]); op[d] = f + 1;
                            end
                            else begin
                                for ( j = op[d] - 1; j >= 0 && j >= op[d] - 14 && f < 0; j = j - 1 )
                                    if ( aq[d][j] === {cx[3], cx[2], dw} ) f = j;
                                if ( f >= 0 ) mux_rep[d] = mux_rep[d] + 1;
                                else begin
                                    $display("DST_MUX_UNKNOWN d=%0d t=%0t got=%h/%b", d, $time, dw, cx[3:2]);
                                    errors = errors + 1;
                                end
                            end
                        end
                    end
                end
        end
        if ( errors > 20 ) $fatal(1, "DST_TOO_MANY_ERRORS");
    end

    function automatic reg df_first(input integer d, input integer l);
        df_first = (l == 0) && (d == 0 ? df[0].rx_first[0] : df[1].rx_first[0]);
    endfunction
    function automatic reg df_last(input integer d, input integer l);
        reg [3:0] v;
        v = d == 0 ? { df[0].rx_last[3], df[0].rx_last[2], df[0].rx_last[1], df[0].rx_last[0] }
                   : { df[1].rx_last[3], df[1].rx_last[2], df[1].rx_last[1], df[1].rx_last[0] };
        df_last = v[l];
    endfunction

    task automatic expect_complete(input string tag);
        integer dd;
        for ( dd = 0; dd < 2; dd = dd + 1 ) begin
            if ( rp[dd] != wn[dd] ) begin
                $display("DST_INCOMPLETE %s d=%0d read=%0d written=%0d", tag, dd, rp[dd], wn[dd]); errors = errors + 1;
            end
        end
    endtask

    task automatic sys_cycles(input integer n);
        repeat ( n ) @( posedge clk_sys );
    endtask

    parameter integer TRACE = 0;
    integer trace_left = 0;
    always @ ( posedge clk_sys )
        if ( trace_left > 0 ) begin
            trace_left = trace_left - 1;
            $display("TRACE t=%0t rst=%b acc=%b ok=%b rd=%b pop=%b push=%b frd=%b rdq=%b cnt=%0d ov=%b fv=%b dout=%h ep=%0d",
                     $time, rst, i_new.acc_sys, i_new.i_rst_window.ok_sys, i_new.dfifo.rx_rd_en, i_new.pop, i_new.push,
                     i_new.fifo_rd, i_new.rd_q, i_new.pb_count, i_new.o_valid, i_new.fifo_valid, i_new.fifo_dout[31:0], epoch);
        end
    task automatic pulse_reset(input integer len);
        if ( TRACE && epoch == 0 ) trace_left = 60;
        @( posedge clk_sys ) begin rst <= 1'b1; epoch <= epoch + 1; end
        sys_cycles(len);
        @( posedge clk_sys ) rst <= 1'b0;
    endtask

    task automatic wait_acc;
        wait ( acc[0] && acc[1] );
        sys_cycles(2);
    endtask

    // random consumer ready
    always @ ( posedge clk_sys ) mux_rd <= rnd(100) < rd_pct;

    integer i, base0, base1, t0, t1, ncyc[2], wn_a[2], skip_a[2];
    initial begin
        sys_cycles(10);
        @( posedge clk_sys ) begin rst <= 1'b0; mrst <= 1'b0; end
        wait_acc;

        // Phase A: random traffic, random consumer, no resets.
        src_on = 1'b1; gap_pct = 45; rd_pct = 70;
        sys_cycles(20000);
        src_on = 1'b0; rd_pct = 100;
        sys_cycles(3000);
        expect_complete("A");
        if ( skipped[0] || skipped[1] ) begin
            $display("DST_SKIP_NO_RESET ref=%0d new=%0d", skipped[0], skipped[1]); errors = errors + 1;
        end
        $display("PHASE_A delivered ref=%0d new=%0d written=%0d", delivered[0], delivered[1], wn[0]);

        // Phase B: preload with the consumer stopped, then drain at full rate.
        rd_pct = 0; sys_cycles(4);
        src_on = 1'b1; gap_pct = 0;
        sys_cycles(400);
        src_on = 1'b0;
        sys_cycles(100);
        base0 = rp[0]; base1 = rp[1];
        rd_pct = 100;
        t0 = 0; t1 = 0;
        for ( i = 0; i < 2000 && (t0 == 0 || t1 == 0); i = i + 1 ) begin
            @( posedge clk_sys );
            if ( t0 == 0 && rp[0] == wn[0] ) t0 = i;
            if ( t1 == 0 && rp[1] == wn[1] ) t1 = i;
        end
        $display("PHASE_B drain_dws=%0d ref_cycles=%0d new_cycles=%0d", wn[0] - base0, t0, t1);
        if ( t0 == 0 || t1 == 0 || t1 > t0 + 4 ) begin
            $display("DST_THROUGHPUT ref=%0d new=%0d", t0, t1); errors = errors + 1;
        end
        expect_complete("B");

        // Phase C: reset pulses swept across live traffic.
        for ( i = 0; i < 60; i = i + 1 ) begin
            src_on = 1'b1; gap_pct = rnd(60); rd_pct = 40 + rnd(61);
            sys_cycles(30 + rnd(400));
            pulse_reset(1 + rnd(4));
            wait_acc;
        end
        // clean tail: everything written after the last window must arrive
        wn_a[0] = wn[0]; wn_a[1] = wn[1];
        sys_cycles(4000);
        src_on = 1'b0; rd_pct = 100;
        sys_cycles(3000);
        expect_complete("C");
        $display("PHASE_C delivered ref=%0d new=%0d skipped ref=%0d new=%0d written=%0d",
                 delivered[0], delivered[1], skipped[0], skipped[1], wn[0]);
        // nothing written after the last reset window may be skipped
        if ( last_skip[0] >= wn_a[0] || last_skip[1] >= wn_a[1] ) begin
            $display("DST_SKIP_AFTER_LAST_RESET ref=%0d/%0d new=%0d/%0d", last_skip[0], wn_a[0], last_skip[1], wn_a[1]);
            errors = errors + 1;
        end

        // Phase D: consumer always ready.
        $display("PHASE_ABC mux_anomalies drop ref=%0d new=%0d repeat ref=%0d new=%0d",
                 mux_drop[0], mux_drop[1], mux_rep[0], mux_rep[1]);
        rd_pct = 100; sys_cycles(4);
        if ( !OUT_EXACT ) begin op[0] = an[0]; op[1] = an[1]; out_exact = 1'b1; end
        src_on = 1'b1; gap_pct = 20;
        sys_cycles(8000);
        src_on = 1'b0;
        sys_cycles(2000);
        expect_complete("D");
        for ( i = 0; i < 2; i = i + 1 )
            if ( op[i] != an[i] ) begin
                $display("DST_MUX_INCOMPLETE d=%0d out=%0d accepted=%0d", i, op[i], an[i]); errors = errors + 1;
            end
        $display("PHASE_D accepted ref=%0d new=%0d (exact mux output)", an[0], an[1]);

        if ( errors == 0 ) $display("DST_MUX_PASS seed=%0d", SEED);
        else $fatal(1, "DST_MUX_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
