// R4: PCIe subsystem reset of the seven clk_sys <-> clk_pcie FIFOs.
//
// Production pcileech_pcie_a7_rst, pcileech_pcie_cfgword_cdc and the four
// modules that own the seven FIFOs reset by rst_subsys_sys:
//   pcileech_pcie_cfg_a7               fifo_64_64 (cfg_tx), fifo_32_32_clk2 (cfg_rx)
//   pcileech_tlps128_cfgspace_shadow   fifo_49_49_clk2 (shd_req), fifo_43_43_clk2 (shd_rsp)
//   pcileech_tlps128_dst_fifo          fifo_134_134_clk2 (dst)
//   pcileech_tlps128_src_fifo          fifo_134_134_clk2_rxfifo (src_data), fifo_1_1_clk2 (src_tok)
// run with the configured Vivado FIFO models (functional netlists exported
// from the out-of-context checkpoints).
//
// Every FIFO gets a monitor (bind) that checks the FIFO Generator reset
// contract for these IPs (independent clocks, asynchronous reset with reset
// synchronization, no safety circuit; PG057 Fig 3-30 and pp. 127-131):
//   SUBSYS_NOACCESS  wr_en/rd_en while rst is high or before NOACCESS_CYCLES
//                    edges of BOTH clocks have passed since rst fell;
//   SUBSYS_RST_SHORT rst high for fewer than MIN_HI edges of either clock
//                    (clocks not running while reset is applied);
//   SUBSYS_RST_GAP   rst re-asserted fewer than MIN_LO edges of either
//                    clock after it fell.
// MIN_HI/MIN_LO = 6 is the same local policy as the COM FIFO sequencer.
//
// Four scoreboards run traffic through every FIFO continuously, including
// while resets happen:
//   A host TX -> src FIFOs -> PCIe side    (packets, 1-8 DWs)
//   B PCIe RX -> dst FIFO  -> host side    (packets, 1-8 DWs)
//   C host cfg read command -> cfg_tx -> cfg_a7 -> cfg_rx -> host
//   D host shadow read -> shd_req -> shadow BRAM -> shd_rsp -> host
// An epoch is one rising edge of rst_subsys_sys (the FIFO reset). Checks:
//   - delivered items are well formed, in order, never duplicated;
//   - nothing offered in an earlier epoch is delivered (stale);
//   - every item offered at least T_SETTLE after the reset fell, and not hit
//     by a later reset, is delivered exactly once (lost);
//   - shadow read data for an address never changes (no reads are written).
// A packet cut at the FIFO output by a reset is counted (TRUNC), not failed:
// downstream drain of a cut packet is a separate R4 item.
//
// CASE 0: running clocks, mixed reset sources (host subsystem reset, global
//         rst, core user reset, core reset).
// CASE 1: clk_pcie stops (with and without the core user reset), resumes.
// CASE 2: adjacent requests 0..20 clk_sys cycles after the previous request
//         ended (host subsystem reset, and the undrained core reset) and
//         after the quarantine ended, and a second request while still in
//         reset.
// CASE 3: frequent host subsystem resets during heavy TX, with downstream
//         stalls of up to 4 us.
// CASE 4: single-beat static TLPs from cfg_a7 with BAR and host traffic and
//         host subsystem resets in between.
//
// TX path: the host subsystem reset bit goes through the production
// pcileech_pcie_tx_drain into pcileech_pcie_a7_rst, and the production
// pcileech_tlps128_sink_mux1 merges the cfg responses, a BAR response model
// (multi-beat packets, reset by rst_subsys like the BAR controller), the host
// TX FIFO and the static TLP source. At the mux output:
//   SUBSYS_TX_CUT      a packet cut (reset or a new first beat before its
//                      last beat) without an abort reset (global rst, PERST#,
//                      core reset, core user reset) since its first beat;
//   SUBSYS_TX_FORM     BAR packet malformed, reordered or duplicated;
//   SUBSYS_TX_AFTER_IDLE a beat while the mux reports idle;
//   SUBSYS_DRAIN_STUCK a host request not applied within 30 us.
`timescale 1ns / 1ps
`include "pcileech_header.svh"

module subsys_fifo_mon #(
    parameter string  NAME    = "fifo",
    parameter integer WIN     = 30,
    parameter integer MIN_HI  = 6,
    parameter integer MIN_LO  = 6
) (
    input rst,
    input wr_clk,
    input rd_clk,
    input wr_en,
    input rd_en
);
    localparam integer BIG = 1000000;
    integer wr_hi = 0, rd_hi = 0;           // edges while rst high
    integer wr_lo = BIG, rd_lo = BIG;       // edges since rst fell (BIG: never reset)
    integer n_wr = 0, n_rd = 0;             // accesses since the last fall
    integer min_gap = BIG, min_hi = BIG;
    bit     seen_fall = 0;

    always @ ( posedge wr_clk ) begin
        if ( wr_en && (rst || wr_lo < WIN || rd_lo < WIN) )
            tb_subsys_vendor.err($sformatf("SUBSYS_NOACCESS %s wr_en rst=%0d wr_lo=%0d rd_lo=%0d", NAME, rst, wr_lo, rd_lo));
        if ( rst ) wr_hi = wr_hi + 1;
        else if ( wr_lo < BIG ) wr_lo = wr_lo + 1;
        if ( wr_en && !rst ) n_wr = n_wr + 1;
    end
    always @ ( posedge rd_clk ) begin
        if ( rd_en && (rst || wr_lo < WIN || rd_lo < WIN) )
            tb_subsys_vendor.err($sformatf("SUBSYS_NOACCESS %s rd_en rst=%0d wr_lo=%0d rd_lo=%0d", NAME, rst, wr_lo, rd_lo));
        if ( rst ) rd_hi = rd_hi + 1;
        else if ( rd_lo < BIG ) rd_lo = rd_lo + 1;
        if ( rd_en && !rst ) n_rd = n_rd + 1;
    end
    always @ ( posedge rst ) begin
        if ( seen_fall ) begin
            if ( wr_lo < min_gap ) min_gap = wr_lo;
            if ( rd_lo < min_gap ) min_gap = rd_lo;
            if ( wr_lo < MIN_LO || rd_lo < MIN_LO )
                tb_subsys_vendor.err($sformatf("SUBSYS_RST_GAP %s wr_lo=%0d rd_lo=%0d", NAME, wr_lo, rd_lo));
        end
        wr_hi = 0;
        rd_hi = 0;
    end
    always @ ( negedge rst ) begin
        if ( wr_hi < min_hi ) min_hi = wr_hi;
        if ( rd_hi < min_hi ) min_hi = rd_hi;
        if ( wr_hi < MIN_HI || rd_hi < MIN_HI )
            tb_subsys_vendor.err($sformatf("SUBSYS_RST_SHORT %s wr_hi=%0d rd_hi=%0d", NAME, wr_hi, rd_hi));
        wr_lo = 0;
        rd_lo = 0;
        n_wr = 0;
        n_rd = 0;
        seen_fall = 1;
    end
    always @ ( tb_subsys_vendor.check_ev ) begin
        $display("SUBSYS_MON %s min_hi=%0d min_gap=%0d wr=%0d rd=%0d", NAME, min_hi, min_gap, n_wr, n_rd);
        if ( n_wr == 0 || n_rd == 0 )
            tb_subsys_vendor.err($sformatf("SUBSYS_COVERAGE %s wr=%0d rd=%0d after the last reset", NAME, n_wr, n_rd));
    end
endmodule

module tb_subsys_vendor;
    bind fifo_64_64               subsys_fifo_mon #(.NAME("cfg_tx"))   u_mon (.rst(rst), .wr_clk(wr_clk), .rd_clk(rd_clk), .wr_en(wr_en), .rd_en(rd_en));
    bind fifo_32_32_clk2          subsys_fifo_mon #(.NAME("cfg_rx"))   u_mon (.rst(rst), .wr_clk(wr_clk), .rd_clk(rd_clk), .wr_en(wr_en), .rd_en(rd_en));
    bind fifo_49_49_clk2          subsys_fifo_mon #(.NAME("shd_req"))  u_mon (.rst(rst), .wr_clk(wr_clk), .rd_clk(rd_clk), .wr_en(wr_en), .rd_en(rd_en));
    bind fifo_43_43_clk2          subsys_fifo_mon #(.NAME("shd_rsp"))  u_mon (.rst(rst), .wr_clk(wr_clk), .rd_clk(rd_clk), .wr_en(wr_en), .rd_en(rd_en));
    bind fifo_134_134_clk2        subsys_fifo_mon #(.NAME("dst"))      u_mon (.rst(rst), .wr_clk(wr_clk), .rd_clk(rd_clk), .wr_en(wr_en), .rd_en(rd_en));
    bind fifo_134_134_clk2_rxfifo subsys_fifo_mon #(.NAME("src_data")) u_mon (.rst(rst), .wr_clk(wr_clk), .rd_clk(rd_clk), .wr_en(wr_en), .rd_en(rd_en));
    bind fifo_1_1_clk2            subsys_fifo_mon #(.NAME("src_tok"))  u_mon (.rst(rst), .wr_clk(wr_clk), .rd_clk(rd_clk), .wr_en(wr_en), .rd_en(rd_en));

    // ------------------------------------------------------------------
    // Errors, clocks, arguments
    // ------------------------------------------------------------------
    integer n_err = 0;
    event   check_ev;
    integer err_class[string];
    function void err(input string msg);
        string key;
        int sp;
        n_err = n_err + 1;
        // class = first two words ("SUBSYS_NOACCESS cfg_tx")
        sp = 0;
        key = msg;
        for ( int i = 0; i < msg.len(); i++ )
            if ( msg[i] == " " ) begin
                sp++;
                if ( sp == 2 ) begin key = msg.substr(0, i - 1); break; end
            end
        if ( err_class.exists(key) ) err_class[key]++; else err_class[key] = 1;
        if ( n_err <= 60 )
            $display("SUBSYS_ERR t=%0t %s", $time, msg);
    endfunction

    integer CASE = 0;
    integer pa;
    integer SEED = 1;
    real    SYS_HALF = 5.0, PCIE_HALF = 8.0, PHASE = 1.3;
    localparam real T_SETTLE = 3000.0;     // ns after the FIFO reset fell: settled

    reg clk_sys = 1'b0, clk_pcie = 1'b0, pcie_run = 1'b1;
    initial begin
        pa = $value$plusargs("CASE=%d", CASE);
        pa = $value$plusargs("SEED=%d", SEED);
        pa = $value$plusargs("SYS_HALF=%f", SYS_HALF);
        pa = $value$plusargs("PCIE_HALF=%f", PCIE_HALF);
        pa = $value$plusargs("PHASE=%f", PHASE);
        $display("SUBSYS_ARGS case=%0d seed=%0d sys_half=%0.2f pcie_half=%0.2f phase=%0.2f", CASE, SEED, SYS_HALF, PCIE_HALF, PHASE);
        fork
            forever #(SYS_HALF) clk_sys = ~clk_sys;
            begin
                #(PHASE);
                forever begin
                    #(PCIE_HALF);
                    if ( pcie_run || clk_pcie )
                        clk_pcie = ~clk_pcie;
                end
            end
        join_none
    end

    // ------------------------------------------------------------------
    // Reset sources and production reset generator
    // ------------------------------------------------------------------
    reg rst = 1'b1, perst_n = 1'b1, rst_core = 1'b0, rst_subsys_host = 1'b0;   // clk_sys
    reg user_rst = 1'b1;                                                        // clk_pcie
    wire rst_pcie_src, rst_pcie_n, rst_subsys_sys, rst_subsys_fifo, rst_subsys, rst_clkpcie, rst_cfgword, cfgword_synced;
    wire soft_rst, tx_stop, tx_idle;
    pcileech_pcie_tx_drain u_drain(
        .clk_sys            ( clk_sys           ),
        .clk_pcie           ( clk_pcie          ),
        .soft_req           ( rst_subsys_host   ),
        .soft_rst           ( soft_rst          ),
        .subsys_rst         ( rst_subsys_sys    ),
        .tx_stop            ( tx_stop           ),
        .tx_idle            ( tx_idle           )
    );

    pcileech_pcie_a7_rst u_rst(
        .clk_sys            ( clk_sys           ),
        .clk_pcie           ( clk_pcie          ),
        .rst                ( rst               ),
        .pcie_perst_n       ( perst_n           ),
        .pcie_rst_core      ( rst_core          ),
        .pcie_rst_subsys    ( soft_rst          ),
        .cfgword_synced     ( cfgword_synced    ),
        .rst_pcie_user      ( user_rst          ),
        .drp_ok             ( 1'b1              ),
        .rst_pcie_src       ( rst_pcie_src      ),
        .rst_pcie_n         ( rst_pcie_n        ),
        .rst_subsys_sys     ( rst_subsys_sys    ),
        .rst_subsys_fifo    ( rst_subsys_fifo   ),
        .rst_subsys         ( rst_subsys        ),
        .rst_clkpcie        ( rst_clkpcie       ),
        .rst_cfgword        ( rst_cfgword       )
    );

    IfShadow2Fifo dshadow();
    reg        shd_rden = 1'b0;
    reg [9:0]  shd_addr = 10'd0;
    assign dshadow.rx_rden       = shd_rden;
    assign dshadow.rx_wren       = 1'b0;
    assign dshadow.rx_be         = 4'b0;
    assign dshadow.rx_data       = 32'b0;
    assign dshadow.rx_addr       = shd_addr;
    assign dshadow.rx_addr_lo    = 1'b0;
    assign dshadow.cfgtlp_wren   = 1'b0;
    assign dshadow.cfgtlp_zero   = 1'b0;
    assign dshadow.cfgtlp_en     = 1'b0;
    assign dshadow.cfgtlp_filter = 1'b1;
    assign dshadow.alltlp_filter = 1'b0;
    assign dshadow.bar_en        = 1'b0;

    wire pcie_cfgtlp_en, pcie_cfgtlp_zero, pcie_cfgtlp_filter, pcie_bar_en, pcie_cfgtlp_wren, pcie_alltlp_filter;
    pcileech_pcie_cfgword_cdc u_cfgword(
        .clk_src            ( clk_sys           ),
        .rst_src            ( rst_cfgword       ),
        .src_word           ( { dshadow.alltlp_filter, dshadow.cfgtlp_wren, dshadow.bar_en,
                                dshadow.cfgtlp_filter, dshadow.cfgtlp_zero, dshadow.cfgtlp_en } ),
        .src_synced         ( cfgword_synced    ),
        .clk_dst            ( clk_pcie          ),
        .dst_word           ( { pcie_alltlp_filter, pcie_cfgtlp_wren, pcie_bar_en,
                                pcie_cfgtlp_filter, pcie_cfgtlp_zero, pcie_cfgtlp_en } )
    );

    // ------------------------------------------------------------------
    // FIFO owners
    // ------------------------------------------------------------------
    IfPCIeFifoCfg dcfg();
    IfPCIeSignals ctx();
    IfAXIS128     tlps_static();
    wire [15:0]   pcie_id;
    reg  [63:0]   cfg_tx_data  = 64'd0;
    reg           cfg_tx_valid = 1'b0;
    reg           cfg_rx_rd_en = 1'b0;
    assign dcfg.tx_data   = cfg_tx_data;
    assign dcfg.tx_valid  = cfg_tx_valid;
    assign dcfg.rx_rd_en  = cfg_rx_rd_en;
    assign ctx.cfg_mgmt_rd_wr_done = 1'b0;
    assign ctx.cfg_mgmt_do         = 32'd0;
    assign ctx.cfg_bus_number      = 8'd0;
    assign ctx.cfg_device_number   = 5'd0;
    assign ctx.cfg_function_number = 3'd0;

    pcileech_pcie_cfg_a7 u_cfg(
        .rst                ( rst_subsys        ),
        .rst_sys            ( rst_subsys_sys    ),
        .rst_fifo           ( rst_subsys_fifo   ),
        .clk_sys            ( clk_sys           ),
        .clk_pcie           ( clk_pcie          ),
        .dfifo              ( dcfg.mp_pcie      ),
        .ctx                ( ctx.mpm           ),
        .tlps_static        ( tlps_static.source ),
        .pcie_id            ( pcie_id           )
    );

    IfAXIS128 rxs();        // PCIe RX stream: dst FIFO and shadow
    IfAXIS128 cfg_rsp();

    pcileech_tlps128_cfgspace_shadow u_shadow(
        .rst                ( rst_subsys        ),
        .rst_sys            ( rst_subsys_sys    ),
        .rst_fifo           ( rst_subsys_fifo   ),
        .clk_pcie           ( clk_pcie          ),
        .clk_sys            ( clk_sys           ),
        .cfgtlp_en          ( pcie_cfgtlp_en    ),
        .cfgtlp_zero        ( pcie_cfgtlp_zero  ),
        .cfgtlp_wren        ( pcie_cfgtlp_wren  ),
        .tlps_in            ( rxs.sink_lite     ),
        .pcie_id            ( pcie_id           ),
        .tlps_cfg_rsp       ( cfg_rsp.source    ),
        .dshadow2fifo       ( dshadow.shadow    )
    );

    IfPCIeFifoTlp dtlp();
    reg  [31:0] h_tx_data  = 32'd0;
    reg         h_tx_last  = 1'b0;
    reg         h_tx_valid = 1'b0;
    reg         h_rx_rd_en = 1'b0;
    assign dtlp.tx_data  = h_tx_data;
    assign dtlp.tx_last  = h_tx_last;
    assign dtlp.tx_valid = h_tx_valid;
    assign dtlp.rx_rd_en = h_rx_rd_en;

    pcileech_tlps128_dst_fifo u_dst(
        .rst                ( rst_subsys_sys    ),
        .rst_fifo           ( rst_subsys_fifo   ),
        .clk_pcie           ( clk_pcie          ),
        .clk_sys            ( clk_sys           ),
        .tlps_in            ( rxs.sink_lite     ),
        .dfifo              ( dtlp.mp_pcie      )
    );

    IfAXIS128 txs();        // src FIFO output toward the PCIe TX mux

    pcileech_tlps128_src_fifo u_src(
        .rst                ( rst_subsys        ),
        .rst_sys            ( rst_subsys_sys    ),
        .rst_fifo           ( rst_subsys_fifo   ),
        .clk_pcie           ( clk_pcie          ),
        .clk_sys            ( clk_sys           ),
        .dfifo_tx_data      ( dtlp.tx_data      ),
        .dfifo_tx_last      ( dtlp.tx_last      ),
        .dfifo_tx_valid     ( dtlp.tx_valid     ),
        .tlps_out           ( txs.source        )
    );

    // ------------------------------------------------------------------
    // Epochs
    // ------------------------------------------------------------------
    integer epoch = 0;
    realtime last_fall = 0.0;
    bit      stim_on = 1'b1;
    always @ ( posedge rst_subsys_sys ) epoch = epoch + 1;
    // Quarantine is one continuous level from the request until the FIFO
    // sequence is done: it may fall only with done high and no request.
    always @ ( negedge rst_subsys_sys )
        if ( !u_rst.fifo_done || u_rst.subsys_req )
            err($sformatf("SUBSYS_QUAR_EARLY done=%0d req=%0d", u_rst.fifo_done, u_rst.subsys_req));
    // Two-hop release order: the clk_pcie subsystem reset is released before
    // the clk_sys quarantine, and the FIFO pins before both windows open.
    always @ ( negedge rst_subsys_sys )
        if ( rst_subsys || rst_subsys_fifo )
            err($sformatf("SUBSYS_RELEASE_ORDER rst_subsys=%0d fifo=%0d", rst_subsys, rst_subsys_fifo));
    always @ ( negedge rst_subsys_sys ) last_fall = $realtime;
    function bit settled_now();
        return !rst_subsys_sys && ($realtime - last_fall >= T_SETTLE);
    endfunction

    // ------------------------------------------------------------------
    // A: host TX packets -> src FIFOs -> PCIe side
    // DW = { id[19:0], len[3:0], idx[3:0], 4'hA }
    // ------------------------------------------------------------------
    localparam integer MAXP = 16384;
    integer  a_ep [0:MAXP-1];
    bit      a_req[0:MAXP-1];
    bit      a_done[0:MAXP-1];
    bit      a_got[0:MAXP-1];
    integer  a_id = 0, a_len = 1, a_idx = 0, a_last_id = -1, a_trunc = 0, a_deliv = 0;
    integer  a_cur = -1, a_cnt = 0, a_cur_len = 0, a_cur_ep = 0;

    always @ ( posedge clk_sys ) begin
        h_tx_valid <= 1'b0;
        h_tx_last  <= 1'b0;
        if ( (stim_on || a_idx != 0) && ($urandom % 100) < 55 && a_id < MAXP ) begin
            if ( a_idx == 0 ) begin
                a_len        = 1 + ($urandom % 8);
                a_ep[a_id]   = epoch;
                a_req[a_id]  = settled_now();
                a_done[a_id] = 1'b0;
                a_got[a_id]  = 1'b0;
            end
            h_tx_valid <= 1'b1;
            h_tx_data  <= { a_id[19:0], a_len[3:0], a_idx[3:0], 4'hA };
            h_tx_last  <= (a_idx == a_len - 1);
            if ( a_idx == a_len - 1 ) begin
                a_done[a_id] = 1'b1;
                a_id  = a_id + 1;
                a_idx = 0;
            end
            else
                a_idx = a_idx + 1;
        end
    end

    task automatic dw_check(input string p, input integer idv, input integer cur, input integer cnt,
                            input integer len, input integer lenv, input integer idxv, input integer tag, input integer tagv);
        if ( idv != cur || lenv != len || idxv != cnt || tagv != tag )
            err($sformatf("SUBSYS_%s_FORM pkt=%0d cnt=%0d got id=%0d len=%0d idx=%0d tag=%0h", p, cur, cnt, idv, lenv, idxv, tagv));
    endtask

    // one DW at the sink: returns 1 at a completed packet
    task automatic a_dw(input [31:0] dw, input bit first, input bit last);
        integer idv, lenv, idxv;
        idv = dw[31:12]; lenv = dw[11:8]; idxv = dw[7:4];
        if ( first ) begin
            if ( a_cur >= 0 ) a_trunc = a_trunc + 1;
            if ( idv >= MAXP || idv <= a_last_id )
                err($sformatf("SUBSYS_A_ORDER id=%0d last=%0d", idv, a_last_id));
            else if ( a_ep[idv] != epoch )
                err($sformatf("SUBSYS_A_STALE id=%0d offered epoch=%0d now=%0d", idv, a_ep[idv], epoch));
            a_cur = idv; a_cnt = 0; a_cur_len = lenv;
            if ( idv < MAXP && idv > a_last_id ) a_last_id = idv;
        end
        else if ( a_cur < 0 ) begin
            err($sformatf("SUBSYS_A_ORPHAN dw=%08h", dw));
            return;
        end
        dw_check("A", idv, a_cur, a_cnt, a_cur_len, lenv, idxv, 4'hA, dw[3:0]);
        a_cnt = a_cnt + 1;
        if ( last ) begin
            if ( a_cnt != a_cur_len )
                err($sformatf("SUBSYS_A_FORM pkt=%0d last at %0d of %0d", a_cur, a_cnt, a_cur_len));
            if ( a_cur < MAXP ) begin
                if ( a_got[a_cur] ) err($sformatf("SUBSYS_A_DUP id=%0d", a_cur));
                a_got[a_cur] = 1'b1;
            end
            a_deliv = a_deliv + 1;
            a_cur = -1;
        end
    endtask

    // ------------------------------------------------------------------
    // BAR response model (mux input 2): pull latency 1, packets of 1-6 beats,
    // DW = { id[19:0], beats[3:0], beat[3:0], 4'hC }; abandons its packet on
    // rst_subsys like the BAR controller.
    // ------------------------------------------------------------------
    IfAXIS128 bar();
    reg  [127:0] bar_tdata = 0;
    reg          bar_tvalid = 0, bar_tlast = 0, bar_first = 0, bar_has = 0;
    integer      bar_id = 0, bar_len = 0, bar_beat = 0;
    bit          bar_active = 0;
    assign bar.tdata    = bar_tdata;
    assign bar.tkeepdw  = 4'b1111;
    assign bar.tvalid   = bar_tvalid;
    assign bar.tlast    = bar_tlast;
    assign bar.tuser    = { 8'd0, bar_first };
    assign bar.has_data = bar_has;
    integer BAR_PCT = 3;

    always @ ( posedge clk_pcie ) begin
        bar_tvalid <= 1'b0;
        bar_tlast  <= 1'b0;
        bar_first  <= 1'b0;
        if ( rst_subsys ) begin
            if ( bar_active ) bar_id = bar_id + 1;   // abandoned: id not reused
            bar_active = 1'b0;
            bar_has   <= 1'b0;
        end
        else begin
            if ( bar.tready && bar_active ) begin
                bar_tvalid <= 1'b1;
                bar_first  <= (bar_beat == 0);
                bar_tlast  <= (bar_beat == bar_len - 1);
                for ( int i = 0; i < 4; i++ )
                    bar_tdata[32*i +: 32] <= { bar_id[19:0], bar_len[3:0], bar_beat[3:0], 4'hC };
                bar_beat = bar_beat + 1;
                if ( bar_beat == bar_len ) begin
                    bar_active = 1'b0;
                    bar_has   <= 1'b0;
                    bar_id     = bar_id + 1;
                end
            end
            else if ( !bar_active && stim_on && ($urandom % 100) < BAR_PCT ) begin
                bar_active = 1'b1;
                bar_len    = 1 + ($urandom % 6);
                bar_beat   = 0;
                bar_has   <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Production TX mux and the downstream (req_gate) pull
    // ------------------------------------------------------------------
    IfAXIS128 txo();
    reg  txo_ready = 1'b0;
    integer STALL_PCT = 0;          // CASE 3: chance per cycle of a stall start
    integer stall = 0;
    assign txo.tready = txo_ready;
    pcileech_tlps128_sink_mux1 u_mux(
        .clk_pcie           ( clk_pcie          ),
        .rst                ( rst_subsys        ),
        .stop               ( tx_stop           ),
        .idle               ( tx_idle           ),
        .tlps_out           ( txo               ),
        .tlps_in1           ( cfg_rsp.sink      ),
        .tlps_in2           ( bar.sink          ),
        .tlps_in3           ( txs.sink          ),
        .tlps_in4           ( tlps_static.sink  )
    );

    // Aborts: resets that also flush req_gate/dst64 (link session abort).
    integer abort_n = 0;
    reg     user_rst_q = 1'b0, sys_abort_q = 1'b0, dead_q = 1'b0;
    always @ ( posedge clk_sys ) begin
        // a host request applied with clk_pcie dead is a link-session abort;
        // the bench's own clock model decides whether the clock was dead
        if ( u_drain.applied_dead && !dead_q && pcie_run )
            err("SUBSYS_DRAIN_FALSE_DEAD request applied undrained with clk_pcie running");
        if ( ((rst || rst_core || !perst_n) && !sys_abort_q) || (u_drain.applied_dead && !dead_q && !pcie_run) )
            abort_n = abort_n + 1;
        dead_q <= u_drain.applied_dead;
        sys_abort_q <= rst || rst_core || !perst_n;
    end

    // Each rst_subsys episode is an abort if an abort reset happened since the
    // previous episode ended; otherwise it is a host subsystem reset, which
    // must not cut a packet or let a beat through.
    bit     tx_in_pkt = 0, tx_resync = 0, rst_is_abort = 0, rst_subsys_q = 0;
    integer tx_pkt_abort = 0, tx_cut = 0, abort_mark = 0;
    integer bar_cur = -1, bar_cnt = 0, bar_last_id = -1, bar_deliv = 0, st_deliv = 0;
    always @ ( posedge clk_pcie ) begin
        if ( stall > 0 ) stall = stall - 1;
        else if ( STALL_PCT > 0 && ($urandom % 1000) < STALL_PCT ) stall = 50 + ($urandom % 250);
        txo_ready <= (stall == 0) && (($urandom % 100) < 70);
        if ( user_rst && !user_rst_q ) abort_n = abort_n + 1;
        user_rst_q <= user_rst;
        if ( rst_subsys && !rst_subsys_q ) begin
            rst_is_abort = (abort_n != abort_mark);
            abort_mark   = abort_n;
            if ( tx_in_pkt ) begin
                tx_cut = tx_cut + 1;
                if ( !rst_is_abort ) err("SUBSYS_TX_CUT reset inside a packet without an abort");
                tx_resync = 1;
            end
            tx_in_pkt = 0;
            bar_cur   = -1;
        end
        if ( !rst_subsys && rst_subsys_q ) abort_mark = abort_n;
        rst_subsys_q = rst_subsys;
        if ( rst_subsys && txo.tvalid ) begin
            // a beat pulled before the reset; downstream is reset with it
            // only for an abort
            if ( !rst_is_abort ) err("SUBSYS_TX_CUT beat during a host subsystem reset");
        end
        else if ( txo.tvalid && tx_resync && !txo.tuser[0] ) begin
            // tail of a packet cut by an abort: downstream was flushed
        end
        else if ( txo.tvalid ) begin
            tx_resync = 0;
            if ( tx_idle ) err("SUBSYS_TX_AFTER_IDLE beat while the mux reports idle");
            if ( txo.tuser[0] ) begin
                if ( tx_in_pkt ) begin
                    tx_cut = tx_cut + 1;
                    if ( tx_pkt_abort == abort_n ) err("SUBSYS_TX_CUT new packet before the last beat");
                end
                tx_in_pkt    = 1;
                tx_pkt_abort = abort_n;
            end
            else if ( !tx_in_pkt )
                err("SUBSYS_TX_ORPHAN beat outside a packet");
            if ( txo.tdata[3:0] == 4'hF )
                err("SUBSYS_STATIC_MALFORMED_SENT static TLP armed without a valid second beat");
            else if ( txo.tdata[3:0] == 4'hE ) begin
                if ( !txo.tuser[0] || !txo.tlast || txo.tkeepdw != 4'b0001 )
                    err($sformatf("SUBSYS_TX_FORM static beat keep=%b first=%0d last=%0d", txo.tkeepdw, txo.tuser[0], txo.tlast));
                if ( txo.tlast ) st_deliv = st_deliv + 1;
            end
            else if ( txo.tdata[3:0] == 4'hC ) begin
                // BAR packet: all four DWs equal
                if ( txo.tuser[0] ) begin
                    if ( txo.tdata[31:12] <= bar_last_id && bar_last_id >= 0 )
                        err($sformatf("SUBSYS_TX_FORM bar id %0d after %0d", txo.tdata[31:12], bar_last_id));
                    bar_cur = txo.tdata[31:12]; bar_cnt = 0; bar_last_id = bar_cur;
                end
                if ( txo.tdata[31:12] != bar_cur || txo.tdata[7:4] != bar_cnt
                     || txo.tdata[127:96] != txo.tdata[31:0]
                     || txo.tlast != (bar_cnt == txo.tdata[11:8] - 1) )
                    err($sformatf("SUBSYS_TX_FORM bar beat %08h cur=%0d cnt=%0d last=%0d", txo.tdata[31:0], bar_cur, bar_cnt, txo.tlast));
                bar_cnt = bar_cnt + 1;
                if ( txo.tlast ) bar_deliv = bar_deliv + 1;
            end
            else
                for ( int i = 0; i < 4; i++ )
                    if ( txo.tkeepdw[i] )
                        a_dw(txo.tdata[32*i +: 32], txo.tuser[0] && i == 0,
                             txo.tlast && (i == 3 || !txo.tkeepdw[i+1]));
            if ( txo.tlast ) tx_in_pkt = 0;
        end
    end

    // Every host request is applied (soft_rst rises) within 30 us.
    realtime drain_since = -1.0;
    integer  n_soft = 0;
    always @ ( posedge clk_sys ) begin
        if ( rst_subsys_host && drain_since < 0.0 ) drain_since = $realtime;
        if ( soft_rst ) drain_since = -1.0;
        if ( drain_since >= 0.0 && $realtime - drain_since > 30000.0 ) begin
            err("SUBSYS_DRAIN_STUCK host request not applied in 30 us");
            drain_since = -1.0;
        end
    end
    always @ ( posedge soft_rst ) n_soft = n_soft + 1;

    // ------------------------------------------------------------------
    // B: PCIe RX packets -> dst FIFO -> host side
    // DW = { id[19:0], len[3:0], idx[3:0], 4'hB }; id < 8192 keeps DW0[31:25]
    // clear of CfgRd/CfgWr for the shadow.
    // ------------------------------------------------------------------
    integer  b_ep [0:MAXP-1];
    bit      b_req[0:MAXP-1];
    bit      b_got[0:MAXP-1];
    integer  b_id = 0, b_len = 1, b_idx = 0, b_last_id = -1, b_trunc = 0, b_deliv = 0;
    integer  b_cur = -1, b_cnt = 0, b_cur_len = 0;
    reg [127:0] rx_tdata = 0;
    reg [3:0]   rx_tkeep = 0;
    reg         rx_tvalid = 0, rx_tlast = 0, rx_first = 0;
    assign rxs.tdata   = rx_tdata;
    assign rxs.tkeepdw = rx_tkeep;
    assign rxs.tvalid  = rx_tvalid;
    assign rxs.tlast   = rx_tlast;
    assign rxs.tuser   = { 8'd0, rx_first };

    always @ ( posedge clk_pcie ) begin
        rx_tvalid <= 1'b0;
        rx_tlast  <= 1'b0;
        rx_first  <= 1'b0;
        rx_tkeep  <= 4'b0;
        if ( (stim_on || b_idx != 0) && ($urandom % 100) < 45 && b_id < 8192 ) begin
            if ( b_idx == 0 ) begin
                b_len      = 1 + ($urandom % 8);
                b_ep[b_id] = epoch;
                b_req[b_id]= settled_now();
                b_got[b_id]= 1'b0;
            end
            rx_tvalid <= 1'b1;
            rx_first  <= (b_idx == 0);
            for ( int i = 0; i < 4; i++ ) begin
                if ( b_idx + i < b_len ) begin
                    rx_tdata[32*i +: 32] <= { b_id[19:0], b_len[3:0], 4'(b_idx + i), 4'hB };
                    rx_tkeep[i]          <= 1'b1;
                end
                else
                    rx_tdata[32*i +: 32] <= 32'hDEC0DE00 | i;
            end
            if ( b_idx + 4 >= b_len ) begin
                rx_tlast <= 1'b1;
                b_id  = b_id + 1;
                b_idx = 0;
            end
            else
                b_idx = b_idx + 4;
        end
    end

    task automatic b_dw(input [31:0] dw, input bit first, input bit last);
        integer idv, lenv, idxv;
        idv = dw[31:12]; lenv = dw[11:8]; idxv = dw[7:4];
        if ( first ) begin
            if ( b_cur >= 0 ) b_trunc = b_trunc + 1;
            if ( idv >= MAXP || idv <= b_last_id )
                err($sformatf("SUBSYS_B_ORDER id=%0d last=%0d", idv, b_last_id));
            else if ( b_ep[idv] != epoch )
                err($sformatf("SUBSYS_B_STALE id=%0d offered epoch=%0d now=%0d", idv, b_ep[idv], epoch));
            b_cur = idv; b_cnt = 0; b_cur_len = lenv;
            if ( idv < MAXP && idv > b_last_id ) b_last_id = idv;
        end
        else if ( b_cur < 0 ) begin
            err($sformatf("SUBSYS_B_ORPHAN dw=%08h", dw));
            return;
        end
        dw_check("B", idv, b_cur, b_cnt, b_cur_len, lenv, idxv, 4'hB, dw[3:0]);
        b_cnt = b_cnt + 1;
        if ( last ) begin
            if ( b_cnt != b_cur_len )
                err($sformatf("SUBSYS_B_FORM pkt=%0d last at %0d of %0d", b_cur, b_cnt, b_cur_len));
            if ( b_cur < MAXP ) begin
                if ( b_got[b_cur] ) err($sformatf("SUBSYS_B_DUP id=%0d", b_cur));
                b_got[b_cur] = 1'b1;
            end
            b_deliv = b_deliv + 1;
            b_cur = -1;
        end
    endtask

    always @ ( posedge clk_sys ) begin
        h_rx_rd_en <= ($urandom % 100) < 70;
        for ( int i = 0; i < 4; i++ )
            if ( dtlp.rx_valid[i] )
                b_dw(dtlp.rx_data[i], i == 0 && dtlp.rx_first[0], dtlp.rx_last[i]);
    end

    // ------------------------------------------------------------------
    // C: cfg read commands. Address 0x0100 + n (outside ro: data 0) names
    // command n; every 16th command reads the magic at 0x0000 (data 0x0123).
    // D: shadow USB reads of address n % 1024; data per address is fixed.
    // Both use an in-order expected queue.
    // ------------------------------------------------------------------
    typedef struct { integer addr; integer ep; bit req; } exp_t;
    // cfg_a7 rw write: [13] write, [31:16] byte address (rw: bit 15 set),
    // mask and value as two byte-swapped 16-bit words.
    logic [63:0] cfg_wr_q[$];
    task automatic cfg_write(input [15:0] addr, input [15:0] value, input [15:0] mask);
        cfg_wr_q.push_back({ value[7:0], value[15:8], mask[7:0], mask[15:8], 16'h8000 | addr, 16'h2000 });
    endtask
    // Static TLP: one beat with one DW (DW0 valid+last), tag E in DW0[3:0],
    // every 64 core clocks, 3 times (the last one of a series is where a mux
    // left waiting on the static source would stay stuck).
    task automatic program_static();
        cfg_write(16'h001C, 16'h0003, 16'h00FF);   // DW0 valid + last
        cfg_write(16'h001E, 16'h003F, 16'hFFFF);   // sleep mask
        cfg_write(16'h0022, 16'h0E00, 16'hFF00);   // DW0[7:0] = 0x0E
        cfg_write(16'h0050, 16'd3,    16'hFFFF);   // count: exhausted between resets
        cfg_write(16'h0002, 16'h0008, 16'h0008);   // STATIC_TLP_TX_EN (rw bit 19)
    endtask
    // Malformed static TLP, tag F: DW0 valid, no last bit in the first half,
    // DW4 not valid. It must not be armed (an armed one would hang the mux).
    task automatic program_static_malformed();
        cfg_write(16'h001C, 16'h0001, 16'hFFFF);   // DW0 valid only, DW4-7 clear
        cfg_write(16'h001E, 16'h003F, 16'hFFFF);
        cfg_write(16'h0022, 16'h0F00, 16'hFF00);   // DW0[7:0] = 0x0F
        cfg_write(16'h0050, 16'd3,    16'hFFFF);
        cfg_write(16'h0002, 16'h0008, 16'h0008);
    endtask
    exp_t c_q[$];
    exp_t d_q[$];
    integer c_n = 0, c_deliv = 0, c_gap = 0;
    integer d_n = 0, d_deliv = 0, d_gap = 0;
    integer shd_val [0:1023];
    bit     shd_seen[0:1023];

    always @ ( posedge clk_sys ) begin
        cfg_tx_valid <= 1'b0;
        shd_rden     <= 1'b0;
        cfg_rx_rd_en <= ($urandom % 100) < 70;
        if ( c_gap > 0 ) c_gap = c_gap - 1;
        else if ( cfg_wr_q.size() > 0 ) begin
            cfg_tx_data  <= cfg_wr_q.pop_front();      // write: no reply
            cfg_tx_valid <= 1'b1;
            c_gap = 8;
        end
        else if ( stim_on && c_n < 30000 ) begin
            exp_t e;
            e.addr = (c_n % 16 == 15) ? 0 : 16'h0100 + c_n;
            e.ep   = epoch;
            e.req  = settled_now();
            c_q.push_back(e);
            cfg_tx_data  <= { 32'd0, e.addr[15:0], 3'b000, 1'b1, 12'd0 };   // [12] read
            cfg_tx_valid <= 1'b1;
            c_n   = c_n + 1;
            c_gap = 8 + ($urandom % 40);
        end
        if ( d_gap > 0 ) d_gap = d_gap - 1;
        else if ( stim_on ) begin
            exp_t e;
            e.addr = d_n % 1024;
            e.ep   = epoch;
            e.req  = settled_now();
            d_q.push_back(e);
            shd_rden <= 1'b1;
            shd_addr <= e.addr[9:0];
            d_n   = d_n + 1;
            d_gap = 6 + ($urandom % 40);
        end
    end

    task automatic q_match(input string p, ref exp_t q[$], input integer addr, output bit ok);
        ok = 1'b0;
        while ( q.size() > 0 ) begin
            exp_t e;
            e = q.pop_front();
            if ( e.addr == addr ) begin
                if ( e.ep != epoch )
                    err($sformatf("SUBSYS_%s_STALE addr=%0h offered epoch=%0d now=%0d", p, addr, e.ep, epoch));
                ok = 1'b1;
                return;
            end
            if ( e.req && e.ep == epoch )
                err($sformatf("SUBSYS_%s_LOST addr=%0h skipped (epoch %0d)", p, e.addr, e.ep));
        end
        err($sformatf("SUBSYS_%s_UNEXPECTED addr=%0h", p, addr));
    endtask

    always @ ( posedge clk_sys ) begin
        bit ok;
        if ( dcfg.rx_valid ) begin
            q_match("C", c_q, dcfg.rx_data[31:16], ok);
            if ( ok ) begin
                c_deliv = c_deliv + 1;
                if ( dcfg.rx_data[15:0] != (dcfg.rx_data[31:16] == 0 ? 16'h0123 : 16'h0000) )
                    err($sformatf("SUBSYS_C_DATA addr=%0h data=%0h", dcfg.rx_data[31:16], dcfg.rx_data[15:0]));
            end
        end
        if ( dshadow.tx_valid ) begin
            q_match("D", d_q, dshadow.tx_addr, ok);
            if ( ok ) begin
                d_deliv = d_deliv + 1;
                if ( !shd_seen[dshadow.tx_addr] ) begin
                    shd_seen[dshadow.tx_addr] = 1'b1;
                    shd_val[dshadow.tx_addr]  = dshadow.tx_data;
                end
                else if ( shd_val[dshadow.tx_addr] != dshadow.tx_data )
                    err($sformatf("SUBSYS_D_DATA addr=%0h was %08h now %08h", dshadow.tx_addr,
                                  shd_val[dshadow.tx_addr], dshadow.tx_data));
            end
        end
    end

    // Cut packets at a FIFO reset (not failures; see header).
    always @ ( posedge rst_subsys_sys ) begin
        if ( a_cur >= 0 ) begin a_trunc = a_trunc + 1; a_cur = -1; end
        if ( b_cur >= 0 ) begin b_trunc = b_trunc + 1; b_cur = -1; end
    end

    // ------------------------------------------------------------------
    // Reset schedule
    // ------------------------------------------------------------------
    task automatic sys_cycles(input integer n);
        repeat ( n ) @ ( posedge clk_sys );
    endtask
    task automatic wait_us(input real us);
        #(us * 1000.0);
    endtask
    task automatic host_subsys_pulse();
        @ ( posedge clk_sys ) rst_subsys_host <= 1'b1;
        @ ( posedge clk_sys ) rst_subsys_host <= 1'b0;
    endtask

    integer n_resets = 0;
    always @ ( posedge rst_subsys_sys ) n_resets = n_resets + 1;

    initial begin : schedule
        integer k, d;
        pa = $urandom(SEED);
        #200;
        @ ( posedge clk_sys ) rst <= 1'b0;
        fork begin repeat ( 3 ) @ ( posedge clk_pcie ); user_rst <= 1'b0; end join_none
        wait_us(6.0);
        case ( CASE )
        0: for ( k = 0; k < 12; k++ ) begin
               case ( k % 4 )
               0: host_subsys_pulse();
               1: begin @ ( posedge clk_sys ) rst <= 1'b1; sys_cycles(1 + k % 3); rst <= 1'b0; end
               2: begin @ ( posedge clk_pcie ) user_rst <= 1'b1;
                        repeat ( 1 + k % 3 ) @ ( posedge clk_pcie ); user_rst <= 1'b0; end
               3: begin @ ( posedge clk_sys ) rst_core <= 1'b1; sys_cycles(1); rst_core <= 1'b0; end
               endcase
               wait_us(2.0 + ($urandom % 4000) / 1000.0);
           end
        1: for ( k = 0; k < 6; k++ ) begin
               if ( k % 2 == 0 ) begin
                   // core user reset, then the core clock stops and resumes
                   @ ( posedge clk_pcie ) user_rst <= 1'b1;
                   repeat ( 3 ) @ ( posedge clk_pcie );
                   pcie_run = 1'b0;
                   wait_us(1.0 + k * 0.3);
                   pcie_run = 1'b1;
                   repeat ( 1 + 2 * (k % 3) ) @ ( posedge clk_pcie );
                   user_rst <= 1'b0;
               end
               else begin
                   // host subsystem reset while the core clock is stopped:
                   // applied without draining, before the clock returns
                   integer soft0;
                   pcie_run = 1'b0;
                   wait_us(0.5);
                   soft0 = n_soft;
                   host_subsys_pulse();
                   wait_us(0.5);
                   if ( n_soft == soft0 ) err("SUBSYS_DRAIN_EXPECT_DEAD request not applied with clk_pcie stopped");
                   wait_us(k * 0.2);
                   pcie_run = 1'b1;
               end
               wait_us(4.0 + ($urandom % 2000) / 1000.0);
           end
        2: begin
               // The host does not see when the FIFOs are ready, so the next
               // request is spaced from the end of the previous request
               // (u_rst.subsys_req, k < 9) and from the end of the quarantine
               // (rst_subsys_sys, k >= 9).
               // k 18..26 repeat the request-relative spacing with the core
               // reset, which is not drained (the drain itself spaces host
               // requests by its stop/idle round trip).
               int gaps[28] = '{0, 1, 2, 3, 4, 6, 9, 14, 20, 0, 1, 2, 3, 4, 6, 9, 14, 20,
                                0, 1, 2, 3, 4, 6, 9, 14, 20, -1};
               for ( k = 0; k < 28; k++ ) begin
                   d = gaps[k];
                   host_subsys_pulse();
                   if ( d < 0 ) begin
                       sys_cycles(5);              // second request while still in reset
                       host_subsys_pulse();
                   end
                   else begin
                       if ( k < 9 || k >= 18 ) @ ( negedge u_rst.subsys_req );
                       else                    @ ( negedge rst_subsys_sys );
                       sys_cycles(d);
                       if ( k >= 18 ) begin
                           rst_core <= 1'b1; sys_cycles(1); rst_core <= 1'b0;
                       end
                       else
                           host_subsys_pulse();
                   end
                   wait_us(4.0 + ($urandom % 2000) / 1000.0);
               end
           end
        3: begin
               BAR_PCT   = 20;
               STALL_PCT = 4;
               for ( k = 0; k < 24; k++ ) begin
                   host_subsys_pulse();
                   wait_us(1.0 + ($urandom % 3000) / 1000.0);
               end
           end
        4: begin
               // single-beat static TLPs (cfg_a7) with BAR and host traffic,
               // host subsystem resets in between (rw is reset with them)
               BAR_PCT = 10;
               for ( k = 0; k < 8; k++ ) begin
                   if ( k % 2 == 0 ) begin
                       program_static_malformed();
                       wait_us(2.0);
                       // disable before reprogramming: program_static makes
                       // the packet well formed before it rewrites the tag
                       cfg_write(16'h0002, 16'h0000, 16'h0008);
                       cfg_write(16'h0050, 16'd0,    16'hFFFF);
                   end
                   program_static();
                   wait_us(3.0 + ($urandom % 3000) / 1000.0);
                   host_subsys_pulse();
                   wait_us(4.0);
               end
               program_static();
           end
        default: $fatal(1, "SUBSYS_BAD_CASE %0d", CASE);
        endcase
        wait_us(8.0);       // settled traffic after the last reset
        stim_on = 1'b0;
        wait_us(6.0);       // drain
        finish_checks();
    end

    task automatic finish_checks();
        integer lost_a = 0, lost_b = 0, lost_c = 0, lost_d = 0;
        -> check_ev;
        #1;
        for ( int i = 0; i < a_id; i++ )
            if ( a_req[i] && a_done[i] && a_ep[i] == epoch && !a_got[i] ) begin
                lost_a++;
                if ( lost_a <= 5 ) err($sformatf("SUBSYS_A_LOST id=%0d", i));
            end
        for ( int i = 0; i < b_id; i++ )
            if ( b_req[i] && b_ep[i] == epoch && !b_got[i] ) begin
                lost_b++;
                if ( lost_b <= 5 ) err($sformatf("SUBSYS_B_LOST id=%0d", i));
            end
        foreach ( c_q[i] ) if ( c_q[i].req && c_q[i].ep == epoch ) begin
            lost_c++;
            if ( lost_c <= 5 ) err($sformatf("SUBSYS_C_LOST addr=%0h", c_q[i].addr));
        end
        foreach ( d_q[i] ) if ( d_q[i].req && d_q[i].ep == epoch ) begin
            lost_d++;
            if ( lost_d <= 5 ) err($sformatf("SUBSYS_D_LOST addr=%0h", d_q[i].addr));
        end
        $display("SUBSYS_STATS resets=%0d A sent=%0d deliv=%0d trunc=%0d B sent=%0d deliv=%0d trunc=%0d C sent=%0d deliv=%0d D sent=%0d deliv=%0d",
                 n_resets, a_id, a_deliv, a_trunc, b_id, b_deliv, b_trunc, c_n, c_deliv, d_n, d_deliv);
        $display("SUBSYS_TX bar_sent=%0d bar_deliv=%0d static_deliv=%0d mux_cut=%0d soft_applied=%0d", bar_id, bar_deliv, st_deliv, tx_cut, n_soft);
        if ( CASE == 4 && st_deliv < 15 ) err("SUBSYS_LOW_TRAFFIC static");
        if ( drain_since >= 0.0 ) err("SUBSYS_DRAIN_STUCK request pending at the end");
        if ( bar_deliv < 20 ) err("SUBSYS_LOW_TRAFFIC bar");
        if ( n_resets < 4 ) err("SUBSYS_FEW_RESETS");
        if ( a_deliv < 50 || b_deliv < 50 || c_deliv < 20 || d_deliv < 20 ) err("SUBSYS_LOW_TRAFFIC");
        foreach ( err_class[k] ) $display("SUBSYS_ERR_CLASS %s count=%0d", k, err_class[k]);
        if ( n_err == 0 ) begin
            $display("SUBSYS_PASS case=%0d", CASE);
            $finish;
        end
        $fatal(1, "SUBSYS_FAIL case=%0d errors=%0d", CASE, n_err);
    endtask

    initial begin
        #5ms;
        $fatal(1, "SUBSYS_TIMEOUT");
    end
endmodule
