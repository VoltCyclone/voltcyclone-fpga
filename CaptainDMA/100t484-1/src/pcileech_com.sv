//
// PCILeech Buffered Communication Core for either:
//   - FT601 USB3.
//   - FPGA RMII ETHERNET.
//
//
// (c) Ulf Frisk, 2019-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
//`define ENABLE_ETH
`define ENABLE_FT601

module pcileech_com #(
    // 1: FT601 on the compensated MMCM clock (pcileech_ft601_clk/_phy).
    // 0: legacy pcileech_ft601 on the uncompensated pin clock (fallback).
    parameter integer   FT601_PHY_MMCM = 1
) (
    // SYS
    input               clk,                // 100MHz SYSTEM CLK
    input               clk_com,            // COMMUNICATION CORE CLK PIN (FT601 CLK)
    input               rst,
    output              led_state_txdata,
    input               led_state_invert,

    // TO/FROM FIFO
    IfComToFifo.mp_com  dfifo,

`ifdef ENABLE_FT601
    // FT601
    inout   [31:0]      ft601_data,
    output  [3:0]       ft601_be,
    input               ft601_rxf_n,
    input               ft601_txe_n,
    output              ft601_wr_n,
    output              ft601_siwu_n,
    output              ft601_rd_n,
    output              ft601_oe_n
`endif /* ENABLE_FT601 */    
`ifdef ENABLE_ETH
    // ETH
    output              eth_clk50,
    output              eth_rst_n,
    input   [1:0]       eth_rx_data,
    input               eth_crs_dv,
    output              eth_tx_en,
    output  [1:0]       eth_tx_data,
    output              eth_mdc,
    inout               eth_mdio,
    input               eth_rx_err,
    input   [31:0]      eth_cfg_static_addr,
    input               eth_cfg_static_force,
    input   [15:0]      eth_cfg_port,
    output              eth_led_state_red,
    output              eth_led_state_green
`endif /* ENABLE_ETH */
    );

    // ----------------------------------------------------------------------------
    // COMMUNICATION CORE INITIAL ON-BOARD DEFAULT RX-DATA
    // Sometimes there is a need to perform actions - such as setting DRP-related
    // values before the PCIe core is brought online. This is possible by specify
    // "virtual" COM-core initial transmitted values below.
    // ----------------------------------------------------------------------------
    
    localparam integer INITIAL_RX_START = 16;
    localparam integer INITIAL_RX_WORDS = 5;
    bit [63:0] initial_rx [INITIAL_RX_WORDS] = '{
            // Modify data below to set own actions - examples:
            // - send some initial TLP on core startup.
            // - set initial VID/PID if PCIe core has been modified.
            // - write to DRP memory space to alter the core.
            // replace / expand on dummy values below - for syntax of each 64-bit word
            // please consult sources and also device_fpga.c in the LeechCore project.
            64'h00000000_00000000,
            64'h00000000_00000000,
            64'h00000000_00000000,
            64'h00000000_00000000,

            // Bring the PCIe core online from initial hot-reset state. This is done by
            // setting control bit in PCIleech FIFO CMD register. This should ideally be
            // done after DRP&Config actions are completed - but before sending PCIe TLPs.
            64'h00000003_80182377
        };
        
    // ----------------------------------------------------------------------------
    // COM CLOCK:
    // clk_c is the com domain clock. With FT601_PHY_MMCM it is c0 from
    // pcileech_ft601_clk, phase-compensated to the FT601 CLK pin; com_arst is
    // then phy_not_ready, a clk register that is high during rst and whenever
    // the MMCM is not locked to a running FT601 clock. Otherwise clk_c is the
    // pin clock and com_arst is rst.
    // ----------------------------------------------------------------------------
    wire clk_c;
    wire ft601_c180;
    wire com_arst;
`ifdef ENABLE_FT601
    generate if ( FT601_PHY_MMCM ) begin : g_ft601_mmcm_clk
        wire phy_not_ready;
        // Every rst resets the MMCM, and certification then needs at least
        // FT601_STABLE_CYCLES SYS edges, so COM RX data cannot become visible
        // while the initial_rx boot words are muxed onto dfifo.com_dout.
        localparam integer FT601_STABLE_CYCLES = 64;
`ifndef SYNTHESIS
        initial if (FT601_STABLE_CYCLES <= INITIAL_RX_START + INITIAL_RX_WORDS + 1)   // +1: registered boot words
            $fatal(1, "COM boot words can overlap COM RX after rst");
`endif
        pcileech_ft601_clk #(
            .STABLE_CYCLES      ( FT601_STABLE_CYCLES   )
        ) i_ft601_clk (
            .clk                ( clk                   ),
            .rst                ( rst                   ),
            .ft601_clk          ( clk_com               ),
            .c0                 ( clk_c                 ),
            .c180               ( ft601_c180            ),
            .phy_not_ready      ( phy_not_ready         )
        );
        assign com_arst = phy_not_ready;
    end
    else begin : g_ft601_pin_clk
        assign clk_c      = clk_com;
        assign ft601_c180 = 1'b0;
        assign com_arst   = rst;
    end
    endgenerate
`else
    assign clk_c      = clk_com;
    assign ft601_c180 = 1'b0;
    assign com_arst   = rst;
`endif /* ENABLE_FT601 */

    // ----------------------------------------------------------------------------
    // RESETS:
    // rst is a clk-domain register. rst_com is the com-domain reset: asserted
    // asynchronously from com_arst (so it holds even while the FT601 clock is
    // stopped - the FT601 is itself in reset then) and released synchronously
    // to clk_c.
    // ----------------------------------------------------------------------------
    wire rst_com;
    xpm_cdc_async_rst #(
        .DEST_SYNC_FF       ( 4                     ),
        .INIT_SYNC_FF       ( 0                     ),
        .RST_ACTIVE_HIGH    ( 1                     )
    ) i_cdc_rst_com (
        .src_arst           ( com_arst              ),
        .dest_clk           ( clk_c                 ),
        .dest_arst          ( rst_com               )
    );

    time tickcount64 = 0;
    always @ ( posedge clk )
        tickcount64 <= rst ? 0 : tickcount64 + 1;

    time tickcount64_com = 0;
    always @ ( posedge clk_c )
        tickcount64_com <= rst_com ? 0 : tickcount64_com + 1;

    // Keep traffic quarantined independently of the FIFO's reset pin. After
    // controller-certified clocks return, replay a distinct FIFO reset edge.
    // Both high and low phases count six full periods in BOTH clock domains;
    // six low periods is conservative project policy (PG057 does not specify
    // the endpoints of its six-clock gap). Physical clock loss can precede
    // controller detection; interrupted transactions earn no completion credit.
    wire rst_comrx_fifo, rst_comtx_fifo;
    wire fifo_run_sys, fifo_run_com;
`ifdef ENABLE_FT601
    localparam integer USE_FIFO_REPLAY = FT601_PHY_MMCM;
`else
    localparam integer USE_FIFO_REPLAY = 0;
`endif
    generate if ( USE_FIFO_REPLAY ) begin : g_fifo_replay
        wire fifo_rst, done_sys, done_com;
        pcileech_com_fifo_reset #(.COUNT_CYCLES(6)) i_reset (
            .clk(clk), .clk_com(clk_c), .unavailable(rst || com_arst),
            .rst_com(rst_com), .fifo_rst(fifo_rst), .done(done_sys)
        );
        xpm_cdc_single #(
            .DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .SRC_INPUT_REG(0)
        ) i_done_com (
            .src_clk(clk), .src_in(done_sys),
            .dest_clk(clk_c), .dest_out(done_com)
        );
        assign rst_comrx_fifo = fifo_rst;
        assign rst_comtx_fifo = fifo_rst;
        assign fifo_run_sys = done_sys && !rst && !com_arst;
        // Register the COM qualification locally, with immediate abort. This
        // keeps reset/quarantine terms off the normal backpressure path.
        reg run_com = 1'b0;
        always @(posedge clk_c or posedge rst_com)
            if (rst_com) run_com <= 1'b0;
            else run_com <= done_com;
        assign fifo_run_com = run_com;
        // rx_ready and the stale-acknowledgement argument rely on every rst
        // raising com_arst (and so rst_com) on the next SYS edge; the
        // pcileech_ft601_clk controller guarantees it, and the sequence bench
        // asserts it (COM_RST_WITHOUT_ARST).
    end else begin : g_fifo_legacy
    reg rx_reset = 1'b1;
    always @ ( posedge clk_c or posedge rst_com )
        if ( rst_com )
            rx_reset <= 1'b1;
        else
            rx_reset <= (tickcount64_com < 2);

    // TX clock-crossing FIFO reset (wr_clk = clk, rd_clk = clk_c): a clk
    // register held from rst until the clk_c side has itself left reset.
    // rst_comrx_fifo (a clk_c register, released two clk_c ticks after
    // rst_com) crosses back to clk through an XPM reset synchronizer, so the
    // FIFO's read side has run clk_c for several edges with reset asserted
    // even when ft601_clk was stopped for the whole of rst. No loop: the
    // clk_c side depends only on com_arst. The pulse is never shorter than rst.
    wire rst_comrx_fifo_clk;
    xpm_cdc_async_rst #(
        .DEST_SYNC_FF       ( 4                     ),
        .INIT_SYNC_FF       ( 0                     ),
        .RST_ACTIVE_HIGH    ( 1                     )
    ) i_cdc_rst_comtx_clk (
        .src_arst           ( rx_reset              ),
        .dest_clk           ( clk                   ),
        .dest_arst          ( rst_comrx_fifo_clk    )
    );
    reg tx_reset = 1'b1;
    always @ ( posedge clk )
        tx_reset <= rst || rst_comrx_fifo_clk;

        assign rst_comrx_fifo = rx_reset;
        assign rst_comtx_fifo = tx_reset;
        assign fifo_run_sys = 1'b1;
        assign fifo_run_com = 1'b1;
    end endgenerate
    wire rst_stream_com = rst_com || !fifo_run_com;

    // Boot words are registered: the 64-bit tickcount64 window compare used to
    // drive dfifo.com_dout_valid combinationally, 14 logic levels into the
    // command FIFO write enable and the src FIFO tdata enables. Each word now
    // leaves one SYS cycle later; a rst cycle still masks the output.
    wire        initial_rx_hit      = (tickcount64 >= INITIAL_RX_START) & (tickcount64 < INITIAL_RX_WORDS + INITIAL_RX_START);
    bit         initial_rx_q        = 1'b0;
    bit [63:0]  initial_rx_data     = 64'h0;
    always @ ( posedge clk ) begin
        initial_rx_q    <= ~rst & initial_rx_hit;
        initial_rx_data <= initial_rx_hit ? initial_rx[tickcount64 - INITIAL_RX_START] : 64'h0;
    end
    wire        initial_rx_valid    = initial_rx_q & ~rst;
    
    // ----------------------------------------------------------------------------
    // COMMUNICATION CORE RX DATA BELOW:
    // 1: convert 32-bit signal into 64-bit signal using logic.
    // 2: change clock domain from clk_c to clk using a very shallow fifo.
    //    due to previous 32->64 conversion this will be fine if: 2*clk_c < clk. 
    // ----------------------------------------------------------------------------
    
    wire [31:0] com_rx_data32;
    wire        com_rx_valid32;
    reg [63:0]  com_rx_data64;
    reg [1:0]   com_rx_valid64_dw;
    wire        com_rx_valid64 = com_rx_valid64_dw[0] & com_rx_valid64_dw[1];
    wire [63:0] com_rx_dout;
    wire        com_rx_valid;
    wire        com_rx_full;
   
    always @ ( posedge clk_c )
        if ( rst_stream_com | (~com_rx_valid32 & com_rx_valid64_dw[0] & com_rx_valid64_dw[1]) )
            com_rx_valid64_dw <= 2'b00;
        else if ( com_rx_valid32 && (com_rx_data32 == 32'h66665555) && (com_rx_data64[31:0] == 32'h66665555) )
            // resync logic to allow the host to send resync data that will
            // allow bitstream to sync to proper 32->64-bit sequence in case
            // it should have happen to get out of sync at startup/shutdown.
            com_rx_valid64_dw <= 2'b00;
        else if ( com_rx_valid32 )
            begin
                com_rx_data64 <= (com_rx_data64 << 32) | com_rx_data32;
                com_rx_valid64_dw <= (com_rx_valid64_dw == 2'b01) ? 2'b11 : 2'b01;
            end
    
    fifo_64_64_clk2_comrx i_fifo_64_64_clk2_comrx(
        .rst            ( rst_comrx_fifo            ),
        .wr_clk         ( clk_c                     ),
        .rd_clk         ( clk                       ),
        .din            ( com_rx_data64             ),
        .wr_en          ( com_rx_valid64 && fifo_run_com ),
        .rd_en          ( fifo_run_sys              ),
        .dout           ( com_rx_dout               ),
        .full           ( com_rx_full                ),
        .empty          (                           ),
        .valid          ( com_rx_valid              )
    );
    
    wire com_tx_order_err_seen;
`ifndef ENABLE_FT601
    assign com_tx_order_err_seen = 1'b0;
`endif
    assign dfifo.com_status = {7'b0, com_tx_order_err_seen};
    assign dfifo.com_dout = initial_rx_valid ? initial_rx_data : com_rx_dout;
    assign dfifo.com_dout_valid = initial_rx_valid | (com_rx_valid && fifo_run_sys);
    
    // ----------------------------------------------------------------------------
    // COMMUNICATION CORE TX DATA BELOW:
    // ----------------------------------------------------------------------------
       
    wire [31:0] core_din;
    wire        core_din_empty;
    wire        core_din_wr_en;
    wire        core_din_ready;
    
    wire [31:0] com_tx_data;
    wire        com_tx_wr_en;
    wire        com_tx_almost_full;
    wire        com_tx_prog_full;
    wire        com_tx_prog_empty;
    
    wire        out_buffer1_almost_full;
    wire [255:0] com_tx_word;
    wire        com_tx_word_wr;

    // Host output resynchronization (see pcileech_com_tx_resync). No writes
    // are offered while the TX FIFO is still held in reset.
    pcileech_com_tx_resync i_tx_resync (
        .clk            ( clk                       ),
        .flush          ( rst_comtx_fifo | ~fifo_run_sys ),
        .fifo_af        ( out_buffer1_almost_full   ),
        .din            ( dfifo.com_din             ),
        .din_valid      ( dfifo.com_din_wr_en       ),
        .din_ready      ( dfifo.com_din_ready       ),
        .dout           ( com_tx_word               ),
        .dout_valid     ( com_tx_word_wr            )
    );
    assign led_state_txdata     = com_tx_prog_full ^ led_state_invert;
    
    fifo_32_32_clk1_comtx i_fifo_32_32_clk2_comtx(
        .clk            ( clk_c                     ),
        .srst           ( rst_stream_com            ),
        .din            ( com_tx_data               ),
        .wr_en          ( com_tx_wr_en && fifo_run_com ),
        .rd_en          ( core_din_ready && fifo_run_com ),
        .dout           ( core_din                  ),
        .full           (                           ),
        .almost_full    ( com_tx_almost_full        ),
        .empty          ( core_din_empty            ),
        .prog_empty     ( com_tx_prog_empty         ),  // threshold = 3
        .prog_full      ( com_tx_prog_full          ),  // threshold = 6
        .valid          ( core_din_wr_en            )
    );
    fifo_256_32_clk2_comtx i_fifo_256_32_clk2_comtx(
        .rd_clk         ( clk_c                     ),
        .wr_clk         ( clk                       ),
        .rst            ( rst_comtx_fifo            ),
        .din            ( com_tx_word               ),
        .wr_en          ( com_tx_word_wr && fifo_run_sys && !rst_comtx_fifo ),
        .rd_en          ( ~com_tx_almost_full && fifo_run_com ),
        .dout           ( com_tx_data               ),
        .full           (                           ),
        .almost_full    ( out_buffer1_almost_full   ),
        .empty          (                           ),
        .valid          ( com_tx_wr_en              )
    );

    // ----------------------------------------------------
    // FT601 USB3 BELOW:
    // ----------------------------------------------------
`ifdef ENABLE_FT601

    generate if ( FT601_PHY_MMCM ) begin : g_ft601_phy
        // FIFO reset recovery outlasts rst_com. Do not consume FT601 words
        // until the RX write-domain full flag reports that recovery is over.
        // Latch readiness for this COM session: a later full condition must
        // not reset the PHY and discard unrelated in-flight TX/RX traffic.
        reg rx_ready = 1'b0;
        always @ ( posedge clk_c or posedge rst_com )
            if ( rst_com )
                rx_ready <= 1'b0;
            // fifo_run_com is the synchronized transaction completion; the
            // native FIFO reset is SYS-domain and must not enter this D path.
            else if ( fifo_run_com && !com_rx_full )
                rx_ready <= 1'b1;
        wire rst_phy = rst_com || !rx_ready;

        // TXE_N assumption check (see pcileech_ft601_phy). Status only: the
        // flag sets a sticky clk-domain bit read by the host (+022 bit 2),
        // and changes nothing in the data path.
        wire tx_order_err, tx_order_err_clk;
        xpm_cdc_single #(
            .DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .SRC_INPUT_REG(0)
        ) i_cdc_tx_order_err (
            .src_clk(clk_c), .src_in(tx_order_err),
            .dest_clk(clk), .dest_out(tx_order_err_clk)
        );
        // The PHY clears its flag only once rst_com reaches c0, and the
        // synchronizer adds 4 clk cycles more; com_arst stays high far
        // longer, so ignoring the flag under com_arst keeps a cleared bit
        // from re-latching the previous session's flag.
        reg tx_order_err_seen = 1'b0;
        always @ ( posedge clk )
            if ( rst )
                tx_order_err_seen <= 1'b0;
            else if ( tx_order_err_clk && !com_arst )
                tx_order_err_seen <= 1'b1;
        assign com_tx_order_err_seen = tx_order_err_seen;

        pcileech_ft601_phy i_pcileech_ft601_phy(
            // SYS
            .c0                 ( clk_c                 ),
            .c180               ( ft601_c180            ),
            .rst                ( rst_phy               ),
            .arst               ( com_arst              ),
            // TO/FROM FT601 PADS
            .FT601_DATA         ( ft601_data            ),
            .FT601_BE           ( ft601_be              ),
            .FT601_TXE_N        ( ft601_txe_n           ),
            .FT601_RXF_N        ( ft601_rxf_n           ),
            .FT601_SIWU_N       ( ft601_siwu_n          ),
            .FT601_WR_N         ( ft601_wr_n            ),
            .FT601_RD_N         ( ft601_rd_n            ),
            .FT601_OE_N         ( ft601_oe_n            ),
            // TO/FROM FIFO
            .dout               ( com_rx_data32         ),  // -> [31:0]
            .dout_valid         ( com_rx_valid32        ),  // ->
            .din                ( core_din              ),  // <- [31:0]
            .din_wr_en          ( core_din_wr_en        ),  // <-
            .din_req_data       ( core_din_ready        ),  // ->
            .tx_order_err       ( tx_order_err          )
        );
    end
    else begin : g_ft601_legacy
        assign com_tx_order_err_seen = 1'b0;
        pcileech_ft601 i_pcileech_ft601(
            // SYS
            .clk                ( clk_c                 ),
            .rst                ( rst_com               ),
            // TO/FROM FT601 PADS
            .FT601_DATA         ( ft601_data            ),
            .FT601_BE           ( ft601_be              ),
            .FT601_TXE_N        ( ft601_txe_n           ),
            .FT601_RXF_N        ( ft601_rxf_n           ),
            .FT601_SIWU_N       ( ft601_siwu_n          ),
            .FT601_WR_N         ( ft601_wr_n            ),
            .FT601_RD_N         ( ft601_rd_n            ),
            .FT601_OE_N         ( ft601_oe_n            ),
            // TO/FROM FIFO
            .dout               ( com_rx_data32         ),  // -> [31:0]
            .dout_valid         ( com_rx_valid32        ),  // ->        
            .din                ( core_din              ),  // <- [31:0]
            .din_wr_en          ( core_din_wr_en        ),  // <-
            .din_req_data       ( core_din_ready        )   // ->
        );
    end
    endgenerate
`endif /* ENABLE_FT601 */

    // ----------------------------------------------------
    // UDP Ethernet Below:
    // ----------------------------------------------------
`ifdef ENABLE_ETH

    pcileech_eth i_pcileech_eth(
        // SYS
        .clk                ( clk_c                 ),
        .rst                ( rst_com               ),
        // MAC/RMII
        .eth_clk50          ( eth_clk50             ),
        .eth_rst_n          ( eth_rst_n             ),
        .eth_crs_dv         ( eth_crs_dv            ),
        .eth_rx_data        ( eth_rx_data           ),
        .eth_rx_err         ( eth_rx_err            ),
        .eth_tx_en          ( eth_tx_en             ),
        .eth_tx_data        ( eth_tx_data           ),
        .eth_mdc            ( eth_mdc               ),
        .eth_mdio           ( eth_mdio              ),
        // CFG
        .cfg_static_addr    ( eth_cfg_static_addr   ),  // <- [31:0]
        .cfg_static_force   ( eth_cfg_static_force  ),  // <-
        .cfg_port           ( eth_cfg_port          ),  // <- [15:0]
        // State and Activity LEDs
        .led_state_red      ( eth_led_state_red     ),  // ->
        .led_state_green    ( eth_led_state_green   ),  // ->
        // TO/FROM FIFO
        .dout               ( com_rx_data32         ),  // -> [31:0]
        .dout_valid         ( com_rx_valid32        ),  // ->
        .din                ( core_din              ),  // <- [31:0]
        .din_empty          ( core_din_empty        ),  // <-
        .din_wr_en          ( core_din_wr_en        ),  // <-
        .din_ready          ( core_din_ready        )   // ->       
    );
`endif /* ENABLE_ETH */

endmodule

// Four-phase request/acknowledge counting handshake. Output reset is a single
// SYS register Q shared by both async FIFOs; it freezes during clock loss.
// After the fresh reset is released, one more counted phase holds the FIFO
// enables off for COUNT_CYCLES full periods in BOTH clocks before done, so the
// FIFOs' internal reset synchronizers finish without relying on their flags.
module pcileech_com_fifo_reset #(
    parameter integer COUNT_CYCLES = 6
) (
    input clk, clk_com, unavailable, rst_com,
    output reg fifo_rst = 1'b1,
    output reg done = 1'b0
);
    localparam integer CW = $clog2(COUNT_CYCLES + 1);
    localparam [3:0] WAIT_CLOCK=0, OLD_HIGH=1, OLD_ACK0=2,
        LOW_GAP=3, GAP_ACK0=4, NEW_HIGH=5, NEW_ACK0=6, READY=7,
        POST_LOW=8, POST_ACK0=9;
    reg [3:0] state = WAIT_CLOCK;
    reg request = 1'b0;
    reg [CW-1:0] sys_count = 0, com_count = 0;
    reg ack_com = 1'b0;
    wire request_com, ack_sys;
    xpm_cdc_single #(
        .DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .SRC_INPUT_REG(0)
    ) i_request (
        .src_clk(clk), .src_in(request),
        .dest_clk(clk_com), .dest_out(request_com)
    );
    xpm_cdc_single #(
        .DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .SRC_INPUT_REG(0)
    ) i_ack (
        .src_clk(clk_com), .src_in(ack_com),
        .dest_clk(clk), .dest_out(ack_sys)
    );
    // Starting at zero and testing before incrementing counts full periods,
    // rather than counting the first observed request edge as a period.
    always @(posedge clk_com or posedge rst_com)
        if (rst_com) begin com_count <= 0; ack_com <= 1'b0; end
        else if (!request_com) begin com_count <= 0; ack_com <= 1'b0; end
        else if (com_count == CW'(COUNT_CYCLES)) ack_com <= 1'b1;
        else com_count <= com_count + 1'b1;

    always @(posedge clk)
        if (unavailable) begin
            state <= WAIT_CLOCK;
            request <= 1'b0;
            done <= 1'b0;
            sys_count <= 0;
            // Hold fifo_rst: never shorten an interrupted high/low phase.
        end else begin
            if (request && sys_count < CW'(COUNT_CYCLES))
                sys_count <= sys_count + 1'b1;
            case (state)
                WAIT_CLOCK: if (!ack_sys) begin
                    request <= 1'b1; sys_count <= 0;
                    state <= fifo_rst ? OLD_HIGH : LOW_GAP;
                end
                OLD_HIGH: if (ack_sys && sys_count == CW'(COUNT_CYCLES)) begin
                    request <= 1'b0; state <= OLD_ACK0;
                end
                OLD_ACK0: if (!ack_sys) begin
                    fifo_rst <= 1'b0;
                    request <= 1'b1; sys_count <= 0; state <= LOW_GAP;
                end
                LOW_GAP: if (ack_sys && sys_count == CW'(COUNT_CYCLES)) begin
                    request <= 1'b0; state <= GAP_ACK0;
                end
                GAP_ACK0: if (!ack_sys) begin
                    fifo_rst <= 1'b1;
                    request <= 1'b1; sys_count <= 0; state <= NEW_HIGH;
                end
                NEW_HIGH: if (ack_sys && sys_count == CW'(COUNT_CYCLES)) begin
                    request <= 1'b0; state <= NEW_ACK0;
                end
                NEW_ACK0: if (!ack_sys) begin
                    fifo_rst <= 1'b0;
                    request <= 1'b1; sys_count <= 0; state <= POST_LOW;
                end
                POST_LOW: if (ack_sys && sys_count == CW'(COUNT_CYCLES)) begin
                    request <= 1'b0; state <= POST_ACK0;
                end
                POST_ACK0: if (!ack_sys) begin
                    done <= 1'b1; state <= READY;
                end
                READY: begin end
                default: begin
                    state <= WAIT_CLOCK; request <= 1'b0; done <= 1'b0;
                end
            endcase
        end
`ifndef SYNTHESIS
    initial if (COUNT_CYCLES < 6) $fatal(1, "COM reset policy requires >=6 cycles");
`endif
endmodule



// ------------------------------------------------------------------------
// Host output resynchronization after a COM TX flush (R4).
//
// A COM session abort (rst, or FT601 clock loss / MMCM unlock through
// com_arst) flushes both TX FIFOs and resets the PHY, but pcileech_mux keeps
// its state and resumes where it stopped. Whole 256-bit words can be lost,
// and the PHY can stop in the middle of a word. The host cannot see the
// flush, and its parser (LeechCore 2.23+, FPGA 4.13+) would join a TLP
// prefix sent before the abort to the tail of the same TLP sent after it.
//
// Word layout (pcileech_mux): status DW [255:224] = {c1,c0,c3,c2,c5,c4,E,c6},
// slot j data at [223-32*j -: 32]; nibble cj = {first, last, tag[1:0]},
// tag 0 = TLP, nibble F with data FFFFFFFF = idle. The host ignores idle
// slots, drops a TLP prefix at the next FIRST, and ignores TLP DWs without
// FIRST while it holds no prefix.
//
// After every flush this stage:
// - writes one all-idle word first. If the PHY stopped inside a word, the
//   host's 32-byte parse is misaligned; its 0xE status scan then skips the
//   rest of this word and resumes on the next real status DW;
// - then rewrites every TLP DW as idle until a TLP DW carrying FIRST, so the
//   tail of a TLP cut by the flush never reaches the host.
// Words are registered here and only one write is in flight, so the FIFO's
// almost_full keeps its single-word margin. USB (400 MB/s) is the
// bottleneck; one word every second SYS cycle is 1.6 GB/s.
// ------------------------------------------------------------------------
module pcileech_com_tx_resync(
    input               clk,
    input               flush,          // TX path flushed or held (clk registers)
    input               fifo_af,        // TX FIFO almost full
    input  [255:0]      din,
    input               din_valid,      // word taken when din_valid && din_ready
    output              din_ready,
    output reg [255:0]  dout,
    output reg          dout_valid
);
    localparam [255:0] IDLE_WORD = {32'hFFFFFFEF, {7{32'hFFFFFFFF}}};

    reg skip;           // drop TLP DWs until a FIRST
    reg pad;            // idle word owed after a flush
    initial begin
        skip       = 1'b1;
        pad        = 1'b1;
        dout_valid = 1'b0;
    end

    assign din_ready = !flush && !fifo_af && !pad && !dout_valid;

    function automatic integer nib(input integer j);    // nibble LSB of slot j
        case ( j )
            0: nib = 248;   1: nib = 252;   2: nib = 240;   3: nib = 244;
            4: nib = 232;   5: nib = 236;   default: nib = 224;
        endcase
    endfunction

    reg [255:0] w;
    reg         s;
    always @* begin : filter
        integer j;
        w = din;
        s = skip;
        for ( j = 0; j < 7; j = j + 1 )
            if ( din[nib(j) +: 2] == 2'b00 ) begin
                if ( din[nib(j) + 3] )
                    s = 1'b0;
                else if ( s ) begin
                    w[nib(j) +: 4]      = 4'hF;
                    w[223 - 32*j -: 32] = 32'hFFFFFFFF;
                end
            end
    end

    always @ ( posedge clk ) begin
        dout_valid <= 1'b0;
        if ( flush ) begin
            skip <= 1'b1;
            pad  <= 1'b1;
        end
        else if ( pad ) begin
            if ( !fifo_af && !dout_valid ) begin
                dout       <= IDLE_WORD;
                dout_valid <= 1'b1;
                pad        <= 1'b0;
            end
        end
        else if ( din_valid && din_ready ) begin
            dout       <= w;
            dout_valid <= 1'b1;
            skip       <= s;
        end
    end
endmodule
