//
// PCILeech FPGA.
//
// PCIe controller module - TLP handling for Artix-7.
//
// (c) Ulf Frisk, 2018-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_pcie_tlp_a7(
    input                   rst,            // clk_pcie synchronous reset
    input                   rst_sys,        // clk_sys register: clk_sys logic and clk_sys<->clk_pcie FIFO quarantine
    input                   rst_fifo,       // clk_sys register: rst pins of the clk_sys<->clk_pcie FIFOs
    input                   clk_pcie,
    input                   clk_sys,
    // shadow/BAR/filter controls, already carried into clk_pcie as one word
    input                   cfgtlp_en,
    input                   cfgtlp_zero,
    input                   cfgtlp_filter,
    input                   bar_en,
    input                   cfgtlp_wren,
    input                   alltlp_filter,
    IfPCIeFifoTlp.mp_pcie   dfifo,
    
    // PCIe core receive/transmit data
    IfAXIS128.source        tlps_tx,
    IfAXIS128.sink_lite     tlps_rx,
    IfAXIS128.sink          tlps_static,
    IfShadow2Fifo.shadow    dshadow2fifo,
    input [15:0]            pcie_id,
    IfPCIeSignals.mpro      pcie_ctx,       // read-only PCIe core status
    input                   rst_pcie_user,  // PCIe core user reset (PERST, link down)
    input                   tx_stop,        // clk_pcie register: select no new TX packet
    output                  tx_idle         // clk_pcie register: stopped at a packet boundary
    );
    
    IfAXIS128 tlps_bar_rsp();
    IfAXIS128 tlps_cfg_rsp();
    
    // ------------------------------------------------------------------------
    // Convert received TLPs from PCIe core and transmit onwards:
    // ------------------------------------------------------------------------
    IfAXIS128 tlps_filtered();
    
    pcileech_tlps128_bar_controller i_pcileech_tlps128_bar_controller(
        .rst            ( rst                           ),
        .clk            ( clk_pcie                      ),
        .bar_en         ( bar_en                        ),
        .pcie_id        ( pcie_id                       ),
        .pcie_ctx       ( pcie_ctx                      ),
        .rst_pcie_user  ( rst_pcie_user                 ),
        .tlps_in        ( tlps_rx                       ),
        .tlps_out       ( tlps_bar_rsp.source           )
    );
    
    pcileech_tlps128_cfgspace_shadow i_pcileech_tlps128_cfgspace_shadow(
        .rst            ( rst                           ),
        .rst_sys        ( rst_sys                       ),
        .rst_fifo       ( rst_fifo                      ),
        .clk_pcie       ( clk_pcie                      ),
        .cfgtlp_en      ( cfgtlp_en                     ),
        .cfgtlp_zero    ( cfgtlp_zero                   ),
        .cfgtlp_wren    ( cfgtlp_wren                   ),
        .clk_sys        ( clk_sys                       ),
        .tlps_in        ( tlps_rx                       ),
        .pcie_id        ( pcie_id                       ),
        .dshadow2fifo   ( dshadow2fifo                  ),
        .tlps_cfg_rsp   ( tlps_cfg_rsp.source           )
    );
    
    pcileech_tlps128_filter i_pcileech_tlps128_filter(
        .rst            ( rst                           ),
        .clk_pcie       ( clk_pcie                      ),
        .alltlp_filter  ( alltlp_filter                 ),
        .cfgtlp_filter  ( cfgtlp_filter                 ),
        .tlps_in        ( tlps_rx                       ),
        .tlps_out       ( tlps_filtered.source_lite     )
    );
    
    pcileech_tlps128_dst_fifo i_pcileech_tlps128_dst_fifo(
        .rst            ( rst_sys                       ),  // FIFO quarantine only
        .rst_fifo       ( rst_fifo                      ),
        .clk_pcie       ( clk_pcie                      ),
        .clk_sys        ( clk_sys                       ),
        .tlps_in        ( tlps_filtered.sink_lite       ),
        .dfifo          ( dfifo                         )
    );
    
    // ------------------------------------------------------------------------
    // TX data received from FIFO
    // ------------------------------------------------------------------------
    IfAXIS128 tlps_rx_fifo();
    
    pcileech_tlps128_src_fifo i_pcileech_tlps128_src_fifo(
        .rst            ( rst                           ),
        .rst_sys        ( rst_sys                       ),
        .rst_fifo       ( rst_fifo                      ),
        .clk_pcie       ( clk_pcie                      ),
        .clk_sys        ( clk_sys                       ),
        .dfifo_tx_data  ( dfifo.tx_data                 ),
        .dfifo_tx_last  ( dfifo.tx_last                 ),
        .dfifo_tx_valid ( dfifo.tx_valid                ),
        .tlps_out       ( tlps_rx_fifo.source           )
    );
    
    pcileech_tlps128_sink_mux1 i_pcileech_tlps128_sink_mux1(
        .rst            ( rst                           ),
        .clk_pcie       ( clk_pcie                      ),
        .stop           ( tx_stop                       ),
        .idle           ( tx_idle                       ),
        .tlps_out       ( tlps_tx                       ),
        .tlps_in1       ( tlps_cfg_rsp.sink             ),
        .tlps_in2       ( tlps_bar_rsp.sink             ),
        .tlps_in3       ( tlps_rx_fifo.sink             ),
        .tlps_in4       ( tlps_static                   )
    );

endmodule



// ------------------------------------------------------------------------
// TLP-AXI-STREAM destination:
// Forward the data to output device (FT601, etc.). 
// ------------------------------------------------------------------------
module pcileech_tlps128_dst_fifo(
    input                   rst,            // clk_sys register: FIFO quarantine (window rst)
    input                   rst_fifo,       // clk_sys register: FIFO rst pin
    input                   clk_pcie,
    input                   clk_sys,
    IfAXIS128.sink_lite     tlps_in,
    IfPCIeFifoTlp.mp_pcie   dfifo
);

    wire         fifo_valid;
    wire         fifo_full;
    wire         fifo_pfull;    // prog_full: fewer than CAP_BEATS free (see below)
    wire         fifo_rd;
    wire [133:0] fifo_dout;

    // FIFO reset no-access window (see pcileech_tlps128_fifo_rst_window).
    wire         acc_pcie;      // clk_pcie: write side may access the FIFO
    wire         acc_sys;       // clk_sys:  read side may access the FIFO

    pcileech_tlps128_fifo_rst_window i_rst_window(
        .rst        ( rst               ),
        .clk_sys    ( clk_sys           ),
        .clk_pcie   ( clk_pcie          ),
        .acc_sys    ( acc_sys           ),
        .acc_pcie   ( acc_pcie          )
    );

    // Whole-TLP admission (clk_pcie). The PCIe RX stream cannot be stalled,
    // so a TLP is either written completely or dropped completely:
    // - a TLP is admitted only at its first beat (tuser[0]), and only if the
    //   FIFO is accessible and prog_full is low. prog_full (constant threshold
    //   1787 of 2047) asserts on writes at once and deasserts only after reads
    //   cross into clk_pcie, so it never under-reports. Low means at least
    //   2047 - 1786 - 2 = 259 free slots, counting the 2 writes of the previous
    //   TLP the flag may not show yet: room for CAP_BEATS;
    // - every admitted TLP is capped at CAP_BEATS = 258 beats, the largest
    //   legal TLP (4 header + 1024 data + 1 digest DW = 1029 DW). Beat 258 is
    //   written as the last beat and the rest of a longer TLP is dropped (the
    //   core never delivers one), so an admitted TLP always fits;
    // - beats of a TLP whose first beat was not admitted are dropped;
    // - if a beat of an admitted TLP is refused (FIFO reset; full is only a
    //   backstop now), the rest of that TLP is dropped, so no suffix is ever
    //   written without its head. A reset flushes the head too.
    localparam integer CAP_BEATS = 258;
    bit          rx_admit = 0;  // current RX TLP is being written
    bit  [8:0]   rx_beats = 0;  // beats of the current admitted TLP written
    wire         rx_pass  = tlps_in.tuser[0] ? (acc_pcie && !fifo_full && !fifo_pfull) : (rx_admit && acc_pcie && !fifo_full);
    wire         rx_end   = tlps_in.tlast || (!tlps_in.tuser[0] && rx_beats == CAP_BEATS - 1);
    always @ ( posedge clk_pcie )
        if ( !acc_pcie ) begin
            rx_admit <= 1'b0;
            rx_beats <= 9'd0;
        end
        else if ( tlps_in.tvalid ) begin
            rx_admit <= rx_pass && !rx_end;
            rx_beats <= (rx_pass && !rx_end) ? (tlps_in.tuser[0] ? 9'd1 : rx_beats + 9'd1) : 9'd0;
        end

    fifo_134_134_clk2 i_fifo_134_134_clk2 (
        .rst        ( rst_fifo          ),
        .wr_clk     ( clk_pcie          ),
        .rd_clk     ( clk_sys           ),
        .din        ( { tlps_in.tuser[0], rx_end, tlps_in.tkeepdw, tlps_in.tdata } ),
        .wr_en      ( tlps_in.tvalid && rx_pass ),
        .rd_en      ( fifo_rd           ),
        .dout       ( fifo_dout         ),
        .full       ( fifo_full         ),
        .prog_full  ( fifo_pfull        ),
        .empty      (                   ),
        .valid      ( fifo_valid        )
    );

    // SYS-side prefetch (timing). pcileech_mux pulls with rx_rd_en in cycle n
    // and writes only the response present in n+1. That response is served
    // from registers, so the FIFO's block-RAM output (standard mode, no output
    // register) and the per-DW keep decode stay off the mux index and
    // write-enable chain. Up to three beats are read ahead; a FIFO read is
    // issued only while buffered plus in-flight beats leave room, keeping one
    // beat per cycle. The reset window (acc_sys low) flushes the buffer, as it
    // previously masked the FIFO output. A beat popped in the cycle before rst
    // rises is still presented in the first rst cycle, where the old
    // combinational mask (acc_sys = ok_sys && !rst) dropped it; the output
    // lanes are gated with rst (a clk_sys register) to match.
    reg  [133:0] pb [0:2];
    reg  [1:0]   pb_head  = 2'd0;
    reg  [1:0]   pb_count = 2'd0;
    reg          rd_q     = 1'b0;      // FIFO read issued last cycle
    wire         push     = fifo_valid && acc_sys;
    wire         pop      = dfifo.rx_rd_en && acc_sys && (pb_count != 2'd0);
    wire [2:0]   pb_wsum  = {1'b0, pb_head} + {1'b0, pb_count};
    wire [1:0]   pb_tail  = pb_wsum >= 3'd3 ? pb_wsum[1:0] - 2'd3 : pb_wsum[1:0];
    assign       fifo_rd  = acc_sys && ({1'b0, pb_count} + {2'b0, rd_q} <= 3'd2);

    reg  [127:0] o_data;
    reg          o_first  = 1'b0;
    reg  [3:0]   o_valid  = 4'b0;
    reg  [3:0]   o_last   = 4'b0;
    wire [133:0] head     = pb[pb_head];
    always @ ( posedge clk_sys )
        if ( !acc_sys ) begin
            pb_head  <= 2'd0;
            pb_count <= 2'd0;
            rd_q     <= 1'b0;
            o_valid  <= 4'b0;
            o_last   <= 4'b0;
            o_first  <= 1'b0;
        end
        else begin
            rd_q     <= fifo_rd;
            if ( push )
                pb[pb_tail] <= fifo_dout;
            pb_count <= pb_count + {1'b0, push} - {1'b0, pop};
            if ( pop )
                pb_head <= (pb_head == 2'd2) ? 2'd0 : pb_head + 2'd1;
            // head = { first, tlast, tkeepdw[3:0], tdata[127:0] }
            o_valid  <= pop ? head[131:128] : 4'b0;
            o_first  <= pop && head[133];
            o_last   <= pop ? { head[132] && (head[131:128] == 4'b1111),
                                head[132] && (head[131:128] == 4'b0111),
                                head[132] && (head[131:128] == 4'b0011),
                                head[132] && (head[131:128] == 4'b0001) } : 4'b0;
            if ( pop )
                o_data <= head[127:0];
        end

    assign dfifo.rx_data[0]  = o_data[31:0];
    assign dfifo.rx_data[1]  = o_data[63:32];
    assign dfifo.rx_data[2]  = o_data[95:64];
    assign dfifo.rx_data[3]  = o_data[127:96];
    assign dfifo.rx_first[0] = o_first;
    assign dfifo.rx_first[1] = 0;
    assign dfifo.rx_first[2] = 0;
    assign dfifo.rx_first[3] = 0;
    assign dfifo.rx_last[0]  = o_last[0];
    assign dfifo.rx_last[1]  = o_last[1];
    assign dfifo.rx_last[2]  = o_last[2];
    assign dfifo.rx_last[3]  = o_last[3];
    assign dfifo.rx_valid[0] = o_valid[0] && !rst;
    assign dfifo.rx_valid[1] = o_valid[1] && !rst;
    assign dfifo.rx_valid[2] = o_valid[2] && !rst;
    assign dfifo.rx_valid[3] = o_valid[3] && !rst;

endmodule



// ------------------------------------------------------------------------
// TLP-AXI-STREAM FILTER:
// Filter away certain packet types such as CfgRd/CfgWr or non-Cpl/CplD
// ------------------------------------------------------------------------
module pcileech_tlps128_filter(
    input                   rst,
    input                   clk_pcie,
    input                   alltlp_filter,
    input                   cfgtlp_filter,
    IfAXIS128.sink_lite     tlps_in,
    IfAXIS128.source_lite   tlps_out
);

    bit [127:0]     tdata;
    bit [3:0]       tkeepdw;
    bit             tvalid  = 0;
    bit [8:0]       tuser;
    bit             tlast;
    
    assign tlps_out.tdata   = tdata;
    assign tlps_out.tkeepdw = tkeepdw;
    assign tlps_out.tvalid  = tvalid;
    assign tlps_out.tuser   = tuser;
    assign tlps_out.tlast   = tlast;
    
    // filter=1 drops beats until the next first beat. Reset and configuration
    // start in that state: the RX converter upstream is on the link-session
    // reset and keeps streaming through a subsystem reset, so the first beats
    // seen after release can be the tail of a packet whose head was dropped.
    bit  filter = 1;
    wire first = tlps_in.tuser[0];
    wire is_tlphdr_cpl = first && (
                        (tlps_in.tdata[31:25] == 7'b0000101) ||      // Cpl:  Fmt[2:0]=000b (3 DW header, no data), Cpl=0101xb
                        (tlps_in.tdata[31:25] == 7'b0100101)         // CplD: Fmt[2:0]=010b (3 DW header, data),    CplD=0101xb
                      );
    wire is_tlphdr_cfg = first && (
                        (tlps_in.tdata[31:25] == 7'b0000010) ||      // CfgRd: Fmt[2:0]=000b (3 DW header, no data), CfgRd0/CfgRd1=0010xb
                        (tlps_in.tdata[31:25] == 7'b0100010)         // CfgWr: Fmt[2:0]=010b (3 DW header, data),    CfgWr0/CfgWr1=0010xb
                      );
    wire filter_next = (filter && !first) || (cfgtlp_filter && first && is_tlphdr_cfg) || (alltlp_filter && first && !is_tlphdr_cpl && !is_tlphdr_cfg);
                      
    always @ ( posedge clk_pcie ) begin
        tdata   <= tlps_in.tdata;
        tkeepdw <= tlps_in.tkeepdw;
        tvalid  <= tlps_in.tvalid && !filter_next && !rst;
        tuser   <= tlps_in.tuser;
        tlast   <= tlps_in.tlast;
        // State moves on valid beats only: an idle cycle can still show the
        // previous header's tuser[0] and must not end the drop state.
        filter  <= rst || (tlps_in.tvalid ? filter_next : filter);
    end
    
endmodule



// ------------------------------------------------------------------------
// RX FROM FIFO - TLP-AXI-STREAM:
// Convert 32-bit incoming data to 128-bit TLP-AXI-STREAM to be sent onwards to mux/pcie core. 
// ------------------------------------------------------------------------
module pcileech_tlps128_src_fifo (
    input                   rst,            // clk_pcie synchronous reset
    input                   rst_sys,        // clk_sys register: clk_sys logic and FIFO quarantine
    input                   rst_fifo,       // clk_sys register: FIFO rst pins
    input                   clk_pcie,
    input                   clk_sys,
    input [31:0]            dfifo_tx_data,
    input                   dfifo_tx_last,
    input                   dfifo_tx_valid,
    IfAXIS128.source        tlps_out
);

    // 0: FIFO reset no-access window (see pcileech_tlps128_fifo_rst_window).
    //    Both FIFOs below share rst_sys and the clocks, so one window covers
    //    both; their individual write readiness is taken from each full flag.
    wire        acc_sys;            // clk_sys:  write side may access the FIFOs
    wire        acc_pcie;           // clk_pcie: read side may access the FIFOs
    wire        full_data;
    wire        full_tok;
    wire        pfull_data;         // prog_full: fewer than CAP_DW/4 beats free
    wire        pfull_tok;          // prog_full: fewer than 3 tokens free

    pcileech_tlps128_fifo_rst_window i_rst_window(
        .rst            ( rst_sys                   ),
        .clk_sys        ( clk_sys                   ),
        .clk_pcie       ( clk_pcie                  ),
        .acc_sys        ( acc_sys                   ),
        .acc_pcie       ( acc_pcie                  )
    );

    // 0.1 - whole-packet admission of the host TX stream (clk_sys).
    //       The host stream cannot be stalled and has no first-DW flag, so the
    //       packet boundary is tracked from tx_last by host_mid. host_mid is
    //       not cleared by rst_sys: across a FIFO reset it still knows whether
    //       the next DW starts a packet. A packet is admitted at its first DW
    //       only if the FIFOs are accessible and both prog_full flags are
    //       low (full stays as a backstop); otherwise all its DWs are dropped,
    //       up to and including tx_last. rst_sys inside a packet drops the
    //       rest of it. After an FPGA-wide reset that cut a host packet, at
    //       most the next packet is dropped (resync at tx_last).
    //       Capacity: prog_full never under-reports (writes count at once,
    //       reads only after crossing into clk_sys). Data threshold 763 of
    //       1023: low means at least 1023 - 762 - 2 = 259 free beats, counting
    //       the previous packet's 2 beats the flag may not show yet, while an
    //       admitted packet writes at most 258 (CAP_DW = 1029 DW, the largest
    //       legal TLP: 4 header + 1024 data + 1 digest DW). Token threshold 13
    //       of 15: low means at least 15 - 12 - 2 = 1 free token. A longer
    //       host packet is cut at CAP_DW (its DW 1029 is written as last) and
    //       the rest dropped, so an admitted packet always fits whole.
    localparam integer CAP_DW = 1029;
    bit         host_mid  = 0;      // next host DW continues a packet
    bit         tx_admit  = 0;      // current host packet is being written
    bit [10:0]  tx_dw     = 0;      // DWs of the current admitted packet written
    wire        tx_pass   = host_mid ? tx_admit : (acc_sys && !full_data && !full_tok && !pfull_data && !pfull_tok);
    wire        tx_valid  = dfifo_tx_valid && tx_pass;
    wire        tx_end    = dfifo_tx_last || (host_mid && tx_dw == CAP_DW - 1);

    always @ ( posedge clk_sys ) begin
        if ( dfifo_tx_valid )
            host_mid <= !dfifo_tx_last;
        if ( rst_sys ) begin
            tx_admit <= 1'b0;
            tx_dw    <= 11'd0;
        end
        else if ( dfifo_tx_valid ) begin
            tx_admit <= tx_pass && !tx_end;
            tx_dw    <= (tx_pass && !tx_end) ? (host_mid ? tx_dw + 11'd1 : 11'd1) : 11'd0;
        end
    end

    // 1: 32-bit -> 128-bit state machine:
    bit [127:0] tdata;
    bit [3:0]   tkeepdw = 0;
    bit         tlast;
    bit         first   = 1;
    wire        tvalid  = tlast || tkeepdw[3];

    always @ ( posedge clk_sys )
        if ( rst_sys ) begin
            tkeepdw <= 0;
            tlast   <= 0;
            first   <= 1;
        end
        else begin
            tlast   <= tx_valid && tx_end;
            tkeepdw <= tvalid ? (tx_valid ? 4'b0001 : 4'b0000) : (tx_valid ? ((tkeepdw << 1) | 1'b1) : tkeepdw);
            first   <= tvalid ? tlast : first;
            if ( tx_valid ) begin
                if ( tvalid || !tkeepdw[0] )
                    tdata[31:0]   <= dfifo_tx_data;
                if ( !tkeepdw[1] )
                    tdata[63:32]  <= dfifo_tx_data;
                if ( !tkeepdw[2] )
                    tdata[95:64]  <= dfifo_tx_data;
                if ( !tkeepdw[3] )
                    tdata[127:96] <= dfifo_tx_data;
            end
        end

    // 2.1 - packet count (w/ safe fifo clock-crossing).
    //       Held at 0 while the FIFOs are not accessible (reset and no-access
    //       window): both FIFOs are being flushed, and their outputs are not
    //       valid in that window.
    bit [10:0]  pkt_count       = 0;
    wire        pkt_count_dec   = tlps_out.tvalid && tlps_out.tlast;
    wire        tok_valid;
    wire        pkt_count_inc   = tok_valid && acc_pcie;
    wire [10:0] pkt_count_next  = pkt_count + pkt_count_inc - pkt_count_dec;
    wire        data_valid;
    assign tlps_out.has_data    = acc_pcie && (pkt_count_next > 0);
    assign tlps_out.tvalid      = data_valid && acc_pcie;

    fifo_1_1_clk2 i_fifo_1_1_clk2(
        .rst            ( rst_fifo                  ),
        .wr_clk         ( clk_sys                   ),
        .rd_clk         ( clk_pcie                  ),
        .din            ( 1'b1                      ),
        .wr_en          ( tvalid && tlast && acc_sys ),
        .rd_en          ( acc_pcie                  ),
        .dout           (                           ),
        .full           ( full_tok                  ),
        .prog_full      ( pfull_tok                 ),
        .empty          (                           ),
        .valid          ( tok_valid                 )
    );

    always @ ( posedge clk_pcie ) begin
        pkt_count <= (rst || !acc_pcie) ? 0 : pkt_count_next;
    end

    // 2.2 - submit to output fifo - will feed into mux/pcie core.
    //       together with 2.1 this will form a low-latency "packet fifo".
    fifo_134_134_clk2_rxfifo i_fifo_134_134_clk2_rxfifo(
        .rst            ( rst_fifo                  ),
        .wr_clk         ( clk_sys                   ),
        .rd_clk         ( clk_pcie                  ),
        .din            ( { first, tlast, tkeepdw, tdata } ),
        .wr_en          ( tvalid && acc_sys         ),
        .rd_en          ( tlps_out.tready && (pkt_count_next > 0) && acc_pcie ),
        .dout           ( { tlps_out.tuser[0], tlps_out.tlast, tlps_out.tkeepdw, tlps_out.tdata } ),
        .full           ( full_data                 ),
        .prog_full      ( pfull_data                ),
        .empty          (                           ),
        .valid          ( data_valid                )
    );

endmodule



// ------------------------------------------------------------------------
// RX MUX - TLP-AXI-STREAM:
// Select the TLP-AXI-STREAM with the highest priority (lowest number) and
// let it transmit its full packet.
// Each incoming stream must have latency of 1CLK. 
//
// stop: select no new packet; the selected one runs to its last beat. idle is
// high the cycle after stop is seen with no packet selected (id == 0). A
// source is pulled only while it is selected (id_next); id == 0 means nothing
// was pulled in the previous cycle and, with stop, nothing is pulled now, so
// with idle high no pull response is outstanding either. In reset, nothing
// is selected.
// ------------------------------------------------------------------------
module pcileech_tlps128_sink_mux1 (
    input                       clk_pcie,
    input                       rst,
    input                       stop,
    output reg                  idle = 1'b0,
    IfAXIS128.source            tlps_out,
    IfAXIS128.sink              tlps_in1,
    IfAXIS128.sink              tlps_in2,
    IfAXIS128.sink              tlps_in3,
    IfAXIS128.sink              tlps_in4
);
    bit [2:0] id = 0;
    
    assign tlps_out.has_data    = tlps_in1.has_data || tlps_in2.has_data || tlps_in3.has_data || tlps_in4.has_data;
    
    assign tlps_out.tdata       = (id==1) ? tlps_in1.tdata :
                                  (id==2) ? tlps_in2.tdata :
                                  (id==3) ? tlps_in3.tdata :
                                  (id==4) ? tlps_in4.tdata : 0;
    
    assign tlps_out.tkeepdw     = (id==1) ? tlps_in1.tkeepdw :
                                  (id==2) ? tlps_in2.tkeepdw :
                                  (id==3) ? tlps_in3.tkeepdw :
                                  (id==4) ? tlps_in4.tkeepdw : 0;
    
    assign tlps_out.tlast       = (id==1) ? tlps_in1.tlast :
                                  (id==2) ? tlps_in2.tlast :
                                  (id==3) ? tlps_in3.tlast :
                                  (id==4) ? tlps_in4.tlast : 0;
    
    assign tlps_out.tuser       = (id==1) ? tlps_in1.tuser :
                                  (id==2) ? tlps_in2.tuser :
                                  (id==3) ? tlps_in3.tuser :
                                  (id==4) ? tlps_in4.tuser : 0;
    
    assign tlps_out.tvalid      = (id==1) ? tlps_in1.tvalid :
                                  (id==2) ? tlps_in2.tvalid :
                                  (id==3) ? tlps_in3.tvalid :
                                  (id==4) ? tlps_in4.tvalid : 0;
    
    wire [2:0] id_next_newsel   = tlps_in1.has_data ? 1 :
                                  tlps_in2.has_data ? 2 :
                                  tlps_in3.has_data ? 3 :
                                  tlps_in4.has_data ? 4 : 0;
    
    wire [2:0] id_next          = ((id==0) || (tlps_out.tvalid && tlps_out.tlast)) ? (stop ? 3'd0 : id_next_newsel) : id;
    
    assign tlps_in1.tready      = tlps_out.tready && (id_next==1);
    assign tlps_in2.tready      = tlps_out.tready && (id_next==2);
    assign tlps_in3.tready      = tlps_out.tready && (id_next==3);
    assign tlps_in4.tready      = tlps_out.tready && (id_next==4);
    
    always @ ( posedge clk_pcie ) begin
        id   <= rst ? 0 : id_next;
        idle <= stop && (rst || id == 0);       // id == 0: no pull last cycle, none now
    end

endmodule



// ------------------------------------------------------------------------
// FIFO reset no-access window for the clk_sys <-> clk_pcie FIFO Generator
// FIFOs in this file (independent clocks, asynchronous rst with reset
// synchronization, no safety circuit, full flags reset value 1).
// PG057 v13.2 (Oct 2017), Fig 3-30 "FIFO Asynchronous Reset Timing Without
// Safety Circuit": from rst assertion until 30 cycles of the slowest clock
// after rst deassertion is a No Access Zone; wr_en and rd_en should be low
// and all FIFO outputs are invalid. The slower clock is not known here and
// clk_pcie may stop, so each side counts NOACCESS_CYCLES of its own clock
// after it has seen rst released, and a side is released only when both
// sides have finished counting: the window covers at least NOACCESS_CYCLES
// cycles of the slower clock. After the window, write readiness is taken
// from the full flag (asserted in reset, deasserted when the FIFO is ready
// for writes, PG057 p.130-131); writes while full and reads while empty are
// ignored (p.96-97).
// rst must be a clk_sys register that is high whenever the FIFO rst pin is
// high and falls no earlier than the pin (rst_subsys_sys of
// pcileech_pcie_a7_rst, which falls after the FIFO reset sequence). Running
// clocks during reset (PG057 p.127) and >= 6 slower-clock cycles between
// resets (p.129) are provided by that sequence (pcileech_com_fifo_reset).
// ------------------------------------------------------------------------
module pcileech_tlps128_fifo_rst_window #(
    parameter               NOACCESS_CYCLES = 30
) (
    input                   rst,            // clk_sys register: FIFO rst
    input                   clk_sys,
    input                   clk_pcie,
    output                  acc_sys,        // clk_sys:  FIFO may be accessed
    output                  acc_pcie        // clk_pcie: FIFO may be accessed
);
    localparam          CW   = $clog2(NOACCESS_CYCLES + 1);
    localparam [CW-1:0] LAST = NOACCESS_CYCLES - 1;

    // clk_pcie view of rst: asserted asynchronously (also with clk_pcie
    // stopped), released synchronously to clk_pcie. A clk_pcie edge within
    // the async-clear delay after rst rises can still sample an access; the
    // FIFO's own reset asserts through a similar asynchronous path, so that
    // access lands at the reset edge itself, as for any clk_pcie logic.
    wire rst_pcie;
    xpm_cdc_async_rst #(
        .DEST_SYNC_FF       ( 4                     ),
        .INIT_SYNC_FF       ( 0                     ),
        .RST_ACTIVE_HIGH    ( 1                     )
    ) i_cdc_rst_pcie (
        .src_arst           ( rst                   ),
        .dest_clk           ( clk_pcie              ),
        .dest_arst          ( rst_pcie              )
    );

    wire done_sys_pcie;                 // clk_pcie copy of done_sys
    wire done_pcie_sys;                 // clk_sys copy of done_pcie

    // clk_sys side.
    reg [CW-1:0] cnt_sys  = 0;
    reg          done_sys = 1'b0;
    reg          ok_sys   = 1'b0;
    always @ ( posedge clk_sys )
        if ( rst ) begin
            cnt_sys  <= 0;
            done_sys <= 1'b0;
            ok_sys   <= 1'b0;
        end
        else begin
            if ( !done_sys )
                cnt_sys <= cnt_sys + 1'b1;
            done_sys <= done_sys || (cnt_sys == LAST);
            ok_sys   <= done_sys && done_pcie_sys;
        end
    // rst is a clk_sys register: also gate on it directly, so no access is
    // sampled on the first clk_sys edge after rst rises.
    assign acc_sys = ok_sys && !rst;

    // clk_pcie side.
    reg [CW-1:0] cnt_pcie  = 0;
    reg          done_pcie = 1'b0;
    reg          ok_pcie   = 1'b0;
    always @ ( posedge clk_pcie or posedge rst_pcie )
        if ( rst_pcie ) begin
            cnt_pcie  <= 0;
            done_pcie <= 1'b0;
            ok_pcie   <= 1'b0;
        end
        else begin
            if ( !done_pcie )
                cnt_pcie <= cnt_pcie + 1'b1;
            done_pcie <= done_pcie || (cnt_pcie == LAST);
            ok_pcie   <= done_pcie && done_sys_pcie;
        end
    assign acc_pcie = ok_pcie;

    // Stale copies cannot release a side early: each side clears its own
    // done flag when rst asserts and then counts NOACCESS_CYCLES (> the 4
    // synchronizer stages) of its own clock, by which time the other side's
    // cleared flag has crossed.
    xpm_cdc_single #(
        .DEST_SYNC_FF       ( 4                     ),
        .INIT_SYNC_FF       ( 0                     ),
        .SIM_ASSERT_CHK     ( 0                     ),
        .SRC_INPUT_REG      ( 0                     )   // done_sys is a register
    ) i_cdc_done_sys (
        .src_clk            ( clk_sys               ),
        .src_in             ( done_sys              ),
        .dest_clk           ( clk_pcie              ),
        .dest_out           ( done_sys_pcie         )
    );

    xpm_cdc_single #(
        .DEST_SYNC_FF       ( 4                     ),
        .INIT_SYNC_FF       ( 0                     ),
        .SIM_ASSERT_CHK     ( 0                     ),
        .SRC_INPUT_REG      ( 0                     )   // done_pcie is a register
    ) i_cdc_done_pcie (
        .src_clk            ( clk_pcie              ),
        .src_in             ( done_pcie             ),
        .dest_clk           ( clk_sys               ),
        .dest_out           ( done_pcie_sys         )
    );

endmodule
