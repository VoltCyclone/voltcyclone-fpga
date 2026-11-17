`timescale 1ns/1ps
`include "pcileech_header.svh"

// R4: the host output stream across COM session aborts.
//
// Production pcileech_com with the Vivado FIFO models. As in tb_com_vendor,
// stimulus enters at the clock-controller (com_arst) and PHY stream
// (core_din_ready / core_din) boundaries.
//
// SYS side: a model of pcileech_mux. 256-bit words carry TLP DWs (FIRST on the
// first DW, LAST on the last), command DWs and idle slots, and are offered on
// dfifo.com_din_ready like the mux output queue. The model keeps its position
// across every abort, as the mux does (it resets only on the global rst), so
// the tail of a TLP cut by an abort is offered again after recovery.
//
// Host side: a model of the LeechCore 2.23+ parser (device_fpga.c
// DeviceFPGA_Synch_RxTlpSynchronousInternal; device_fpga_session.h
// DeviceFPGA_Session_TlpFrameStep with FIRST required, FPGA version >= 4.13).
// It parses the DWs leaving the COM TX FIFO (host byte order: the PHY swaps
// bytes) as one continuous session across every abort, the worst case of a
// host read that spans the abort.
//
// Failures:
// - COM_SESSION_SPLICE: a completed TLP is not exactly one whole TLP;
// - COM_SESSION_MALFORMED: the host parser reports a malformed TLP;
// - COM_SESSION_MISFRAME: the host parses a 32-byte frame that does not start on
//   a COM word boundary (other than the one frame allowed below);
// - COM_SESSION_LOST: a TLP that was not in flight at an abort is missing,
//   repeated or out of order;
// - COM_SESSION_PAD: an abort is not followed by an idle word before new data;
// - COM_SESSION_COVERAGE: the run did not exercise a mid-word cut, a dropped
//   tail and a host restart at FIRST.
//
// Allowed, counted as SESSION_RESIDUAL: when the PHY stops inside a word, the
// host applies the remaining slot nibbles of that word to the next DWs it
// receives, which are the idle word. In that one host frame a TLP whose end
// was in the lost part of the word can complete with idle-word DWs (FFFFFFEF,
// FFFFFFFF) in place of its lost DWs, or the parser can report a malformed
// TLP. Repairing that needs a host-side session boundary.
module tb_com_tx_session;
    reg clk = 0, cclk = 0;
    reg sys_run = 1, com_run = 1;
    reg rst = 1, not_ready = 1;
    reg tx_pull = 0;
    real sys_half = 5.0, com_half = 5.0, phase = 1.3;
    integer scenario = 0, seed = 1, rng = 1;
    bit trace = 0;
    initial trace = $test$plusargs("TRACE");
    always @(posedge clk) if (trace && dut.i_tx_resync.dout_valid && dut.i_tx_resync.dout[255:224] == 32'hFFFFFFEF)
        $display("TRACE t=%0t resync wrote the idle word; flush=%b fifo_run_sys=%b rst_comtx_fifo=%b",
                 $time, dut.i_tx_resync.flush, dut.fifo_run_sys, dut.rst_comtx_fifo);
    // one shared generator, so SEED fixes every random choice
    function automatic integer rnd();
        return $unsigned($random(rng)) % 32'h7fffffff;
    endfunction
    wire [31:0] pads;
    wire [3:0] be;
    wire wr_n, rd_n, oe_n, siwu_n;
    IfComToFifo bus();

    pcileech_com dut (
        .clk(clk), .clk_com(cclk), .rst(rst), .dfifo(bus),
        .led_state_txdata(), .led_state_invert(1'b0),
        .ft601_data(pads), .ft601_be(be),
        .ft601_rxf_n(1'b1), .ft601_txe_n(1'b1),
        .ft601_wr_n(wr_n), .ft601_siwu_n(siwu_n),
        .ft601_rd_n(rd_n), .ft601_oe_n(oe_n)
    );

    initial begin
        if ($value$plusargs("SYS_HALF=%f", sys_half)) begin end
        forever begin #(sys_half); if (sys_run) clk = ~clk; else clk = 0; end
    end
    initial begin
        if ($value$plusargs("COM_HALF=%f", com_half)) begin end
        if ($value$plusargs("PHASE=%f", phase)) begin end
        #(phase);
        forever begin #(com_half); if (com_run) cclk = ~cclk; else cclk = 0; end
    end
    initial begin
        force dut.clk_c = cclk;
        force dut.com_arst = not_ready;
        force dut.com_rx_data32 = 32'h0;
        force dut.com_rx_valid32 = 1'b0;
        force dut.core_din_ready = tx_pull;
    end

    // ---------------------------------------------------------------------
    // Encoding
    // ---------------------------------------------------------------------
    localparam integer NTLP  = 2400;
    localparam integer MAXDW = 260;     // TLP_RX_MAX_SIZE_IN_DWORDS
    localparam [31:0]  IDLE0 = 32'hFFFFFFEF;
    localparam [31:0]  IDLE  = 32'hFFFFFFFF;

    // TLP DW: bits [7:4] = E, so to a misaligned host every TLP DW looks
    // like a status DW (host byte order puts these bits on top).
    function automatic [31:0] tlp_dw(input integer id, input integer i);
        return {4'hA, id[11:0], i[7:0], 8'hE1};
    endfunction
    function automatic bit is_tlp_dw(input [31:0] d);
        return d[31:28] == 4'hA && d[7:0] == 8'hE1;
    endfunction
    function automatic [31:0] bswap(input [31:0] d);
        return {d[7:0], d[15:8], d[23:16], d[31:24]};
    endfunction
    function automatic integer nib(input integer j);    // as pcileech_mux
        case (j)
            0: return 248; 1: return 252; 2: return 240; 3: return 244;
            4: return 232; 5: return 236; default: return 224;
        endcase
    endfunction

    // ---------------------------------------------------------------------
    // SYS source: pcileech_mux model
    // ---------------------------------------------------------------------
    integer tlp_len [0:NTLP-1];
    bit     started [0:NTLP-1];         // a DW of the TLP reached the COM
    bit     emitted_last [0:NTLP-1];    // its last DW left the COM TX FIFO
    bit     may_lose [0:NTLP-1];        // in flight at an abort
    bit     got [0:NTLP-1];
    integer src_id = 0, src_idx = 0, cmd_cnt = 0;
    integer word_lo = 0, word_hi = -1;  // TLP ids in the offered word
    reg [255:0] word = 0;
    reg src_on = 0;
    integer accepted = 0, filtered = 0;

    // Offer pacing: trickle phases keep the COM FIFOs nearly empty, burst
    // phases fill them, so aborts find anything from no word to many.
    reg src_gate = 1'b0, burst = 1'b0;
    always @(posedge clk) begin
        if ((rnd() % 400) == 0) burst <= !burst;
        src_gate <= burst || ((rnd() % 100) < 3);
    end
    assign bus.com_din = word;
    assign bus.com_din_wr_en = src_on && src_gate;

    // Build the next word; never all idle (an all-idle status DW is the
    // COM's own idle word).
    task automatic build_word(output reg [255:0] w, output integer lo, output integer hi);
        integer j, r;
        bit any;
        w = 0; lo = src_id; hi = -1; any = 0;
        for (j = 0; j < 7; j = j + 1) begin
            r = rnd() % 16;
            if (src_id < NTLP && r < 11) begin
                w[nib(j) +: 4] = {src_idx == 0, src_idx == tlp_len[src_id] - 1, 2'b00};
                w[223 - 32*j -: 32] = tlp_dw(src_id, src_idx);
                hi = src_id;
                any = 1;
                src_idx = src_idx + 1;
                if (src_idx == tlp_len[src_id]) begin
                    src_id = src_id + 1;
                    src_idx = 0;
                end
            end else if (r < 13 || (j == 6 && !any)) begin
                w[nib(j) +: 4] = 4'h3;
                w[223 - 32*j -: 32] = {8'hC3, cmd_cnt[15:0], 8'hE2};
                cmd_cnt = cmd_cnt + 1;
                any = 1;
            end else begin
                w[nib(j) +: 4] = 4'hF;
                w[223 - 32*j -: 32] = IDLE;
            end
        end
        w[231:228] = 4'hE;
    endtask

    always @(posedge clk) begin : source
        reg [255:0] nw;
        integer lo, hi, k;
        if (src_on && src_gate && bus.com_din_ready) begin
            accepted = accepted + 1;
            for (k = word_lo; k <= word_hi; k = k + 1) started[k] = 1;
            if (dut.i_tx_resync.w !== word) filtered = filtered + 1;
            if (src_id >= NTLP) begin
                src_on <= 1'b0;
            end else begin
                build_word(nw, lo, hi);
                word <= nw; word_lo = lo; word_hi = hi;
            end
        end
    end

    // ---------------------------------------------------------------------
    // Host: LeechCore 2.23+ parser model
    // ---------------------------------------------------------------------
    reg [31:0] hq [$];          // received, not yet parsed (host byte order)
    longint hidx = 0;           // host index of hq[0]
    longint rx_count = 0;       // DWs received
    longint grid = 0;           // a COM word boundary (host index)
    longint cut [$];            // host index of each post-abort idle word
    bit     f_in = 0;
    integer cdw = 0;
    reg [31:0] tlp [0:MAXDW-1];
    integer delivered = 0, restarts = 0, residual = 0, ignored = 0, skipped = 0;
    integer next_id = 0;
    integer aborts = 0, midword = 0;
    bit     idle_due = 1;       // an idle word must come next (power-up/abort)
    integer idle_left = 0;      // DWs of the idle word still to come
    integer before_idle = 0;    // DWs received after an abort, before its idle word

    // COM word grid in force at host index s: the last idle word at or before s.
    function automatic longint grid_of(input longint s);
        longint g;
        g = 0;
        foreach (cut[k]) if (cut[k] <= s) g = cut[k];
        return g;
    endfunction
    function automatic bit stale_frame(input longint s);
        foreach (cut[k]) if (s < cut[k] && cut[k] < s + 8) return 1;
        return 0;
    endfunction

    task automatic complete(input bit stale);
        integer i, id, m;
        bit whole, resid;
        reg [31:0] f;
        f = bswap(tlp[0]);
        id = f[27:16];
        m = 0;      // leading DWs that match TLP id
        if (is_tlp_dw(f) && id < NTLP)
            while (m < cdw && bswap(tlp[m]) == tlp_dw(id, m)) m = m + 1;
        whole = is_tlp_dw(f) && id < NTLP && m == cdw && cdw == tlp_len[id];
        // residual: a valid prefix of one in-flight TLP, then only DWs of
        // the COM idle word (its status DW FFFFFFEF, then FFFFFFFF)
        resid = 0;
        if (!whole) begin
            resid = stale && (m == 0 || may_lose[id]);
            for (i = m; i < cdw; i = i + 1)
                if (bswap(tlp[i]) != IDLE && bswap(tlp[i]) != IDLE0) resid = 0;
        end
        if (whole) begin
            if (id < next_id || got[id])
                $fatal(1, "COM_SESSION_LOST TLP %0d repeated or out of order (next %0d)", id, next_id);
            for (i = next_id; i < id; i = i + 1)
                if (!may_lose[i])
                    $fatal(1, "COM_SESSION_LOST TLP %0d skipped, not in flight at an abort", i);
            got[id] = 1;
            next_id = id + 1;
            delivered = delivered + 1;
        end else if (resid) begin
            residual = residual + 1;
            $display("SESSION_RESIDUAL t=%0t TLP %0d: %0d valid DWs then %0d idle-word DWs (length %0d)",
                     $time, id, m, cdw - m, id < NTLP ? tlp_len[id] : -1);
        end else begin
            $display("  first DW %h, %0d DWs match TLP %0d (length %0d)", f, m, id, id < NTLP ? tlp_len[id] : -1);
            for (i = m; i < cdw && i < m + 12; i = i + 1)
                $display("  dw[%0d] = %h", i, bswap(tlp[i]));
            $fatal(1, "COM_SESSION_SPLICE completed TLP of %0d DWs is not one whole TLP (stale frame %0d)", cdw, stale);
        end
    endtask

    task automatic malformed(input bit stale);
        if (!stale) $fatal(1, "COM_SESSION_MALFORMED at host index %0d", hidx);
        residual = residual + 1;
        $display("SESSION_RESIDUAL t=%0t malformed TLP in the frame after a mid-word cut", $time);
    endtask

    task automatic step(input [3:0] n, input [31:0] d, input bit stale);
        if (n[1:0] != 2'b00) return;                 // not a TLP DW
        if (n[3]) begin
            if (f_in) restarts = restarts + 1;      // prefix dropped at FIRST
            f_in = 1; cdw = 0;
        end else if (!f_in) begin
            ignored = ignored + 1;                  // headless DW ignored
            return;
        end
        if (cdw >= MAXDW) begin
            f_in = 0; cdw = 0; malformed(stale); return;
        end
        tlp[cdw] = d;
        cdw = cdw + 1;
        if (n[2]) begin
            f_in = 0;
            if (cdw < 3) malformed(stale);
            else complete(stale);
            cdw = 0;
        end
    endtask

    task automatic host_parse;
        reg [31:0] st;
        bit stale;
        integer j;
        while (hq.size() >= 8) begin
            if (hq[0] == 32'h55556666 || hq[0][31:28] != 4'hE) begin
                skipped = skipped + 1;              // "Bad no-header data"
                void'(hq.pop_front()); hidx = hidx + 1;
                continue;
            end
            stale = stale_frame(hidx);
            if (!stale && ((hidx - grid_of(hidx)) % 8) != 0)
                $fatal(1, "COM_SESSION_MISFRAME host frame at %0d, COM words at %0d+8k", hidx, grid_of(hidx));
            st = hq[0];
            for (j = 0; j < 7; j = j + 1)
                step(st[4*j +: 4], hq[j + 1], stale);
            repeat (8) void'(hq.pop_front());
            hidx = hidx + 8;
        end
    endtask

    // Idle-word failures are reported at the end, so that a host-visible
    // failure they cause (MISFRAME, SPLICE) is reported first.
    string pad_err = "";
    task automatic pad_fail(input string msg);
        if (pad_err == "") begin
            pad_err = msg;
            $display("SESSION_PAD_VIOLATION t=%0t %s", $time, msg);
        end
    endtask

    always @(posedge cclk) begin : host
        reg [31:0] d;
        integer id;
        #1;
        if (dut.core_din_wr_en) begin
            d = dut.core_din;
            if (idle_left > 0) begin
                if (d !== IDLE) pad_fail($sformatf("idle word broken: %h", d));
                idle_left = idle_left - 1;
            end else if (d === IDLE0) begin
                if (trace) $display("TRACE t=%0t idle word at %0d aborts=%0d due=%0d", $time, rx_count, aborts, idle_due);
                // Outside an abort an all-idle word is an ordinary word whose
                // TLP slots the COM blanked (dropped tail); it is on the grid.
                if (idle_due) begin
                    if (((rx_count - grid) % 8) != 0) midword = midword + 1;
                    cut.push_back(rx_count);
                    grid = rx_count;
                    idle_due = 0;
                end else if (((rx_count - grid) % 8) != 0)
                    pad_fail("all-idle word off the word grid");
                idle_left = 7;
            end else if (idle_due) begin
                // old-session DWs still leaving before the flush took effect
                before_idle = before_idle + 1;
                if (before_idle > 8 || aborts == 0)
                    pad_fail($sformatf("%0d DWs after an abort before its idle word", before_idle));
            end
            if (is_tlp_dw(d)) begin
                id = d[27:16];
                if (id < NTLP && d[15:8] == tlp_len[id] - 1) emitted_last[id] = 1;
            end
            hq.push_back(bswap(d));
            rx_count = rx_count + 1;
            host_parse();
        end
    end

    // FT601 TXE model: the PHY takes a DW on about one cycle in three, so
    // both TX FIFOs hold several words when an abort comes.
    always @(posedge cclk) tx_pull <= (rnd() % 100) < 35;

    // ---------------------------------------------------------------------
    // Aborts
    // ---------------------------------------------------------------------
    task automatic abort(input integer kind, input bit at_boundary);
        integer k;
        longint goal;
        // Cut either on or off a word boundary of the DWs leaving the FIFO.
        do @(posedge cclk); while (!(dut.core_din_wr_en &&
            ((((rx_count - grid) % 8) == 0) == at_boundary)));
        if (kind == 1) begin @(negedge cclk); com_run = 0; end
        if (kind == 2) begin @(negedge clk); sys_run = 0; end
        #2.1; not_ready = 1;
        if (trace) $display("TRACE t=%0t abort %0d kind %0d at %0d", $time, aborts, kind, rx_count);
        // Every TLP with a DW inside the COM and its last DW not yet out may
        // be lost; the source resumes inside its current TLP after recovery.
        for (k = 0; k < NTLP; k = k + 1)
            if (started[k] && !emitted_last[k]) may_lose[k] = 1;
        if (src_id < NTLP && src_idx != 0) may_lose[src_id] = 1;
        aborts = aborts + 1;
        idle_due = 1;
        before_idle = 0;
        #150;
        sys_run = 1; com_run = 1;
        repeat (20) @(negedge clk);
        repeat (20) @(negedge cclk);
        #2.1; not_ready = 0;
        goal = rx_count + 150 + (rnd() % 600);
        wait (rx_count >= goal || !src_on);
    endtask

    initial begin
        integer k;
        if ($value$plusargs("CASE=%d", scenario)) begin end
        if ($value$plusargs("SEED=%d", seed)) begin end
        rng = seed;
        for (k = 0; k < NTLP; k = k + 1) begin
            tlp_len[k] = 3 + (rnd() % 38);       // 3..40 DWs
            started[k] = 0; emitted_last[k] = 0; may_lose[k] = 0; got[k] = 0;
        end
        begin
            reg [255:0] w0; integer lo, hi;
            build_word(w0, lo, hi);
            word = w0; word_lo = lo; word_hi = hi;
        end
        #300.2; rst = 0; not_ready = 0;
        repeat (100) @(negedge clk);
        repeat (100) @(negedge cclk);
        src_on = 1;
        wait (rx_count >= 200);
        for (k = 0; k < 12 && src_on; k = k + 1)
            abort(scenario, k % 3 == 2);
        wait (!src_on);
        // drain: everything accepted must leave the COM
        begin
            longint last;
            do begin
                last = rx_count;
                repeat (500) @(negedge cclk);
            end while (rx_count != last);
        end
        for (k = 0; k < NTLP; k = k + 1)
            if (!got[k] && !may_lose[k])
                $fatal(1, "COM_SESSION_LOST TLP %0d never delivered, not in flight at an abort", k);
        if (idle_due || idle_left != 0)
            pad_fail("the last abort was not followed by an idle word");
        if (pad_err != "")
            $fatal(1, "COM_SESSION_PAD %s", pad_err);
        if (aborts != 12 || midword == 0 || filtered == 0 || restarts == 0 || delivered < NTLP / 8)
            $fatal(1, "COM_SESSION_COVERAGE aborts=%0d midword=%0d filtered=%0d restarts=%0d delivered=%0d",
                   aborts, midword, filtered, restarts, delivered);
        $display("COM_SESSION_PASS case=%0d seed=%0d aborts=%0d midword=%0d delivered=%0d lost=%0d filtered_words=%0d restarts=%0d ignored=%0d skipped=%0d residual=%0d words=%0d",
                 scenario, seed, aborts, midword, delivered, NTLP - delivered, filtered,
                 restarts, ignored, skipped, residual, accepted);
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1, "COM_SESSION_TIMEOUT rx=%0d delivered=%0d src_on=%0d", rx_count, delivered, src_on);
    end
endmodule
