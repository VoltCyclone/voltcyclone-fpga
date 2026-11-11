//
// PCILeech FPGA.
//
// PCIe module for Artix-7.
//
// (c) Ulf Frisk, 2018-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_pcie_a7(
    input                   clk_sys,
    input                   rst,

    // PCIe fabric
    output  [0:0]           pcie_tx_p,
    output  [0:0]           pcie_tx_n,
    input   [0:0]           pcie_rx_p,
    input   [0:0]           pcie_rx_n,
    input                   pcie_clk_p,
    input                   pcie_clk_n,
    input                   pcie_perst_n,
    
    // State and Activity LEDs
    output                  led_state,
    
    // PCIe <--> FIFOs
    IfPCIeFifoCfg.mp_pcie   dfifo_cfg,
    IfPCIeFifoTlp.mp_pcie   dfifo_tlp,
    IfPCIeFifoCore.mp_pcie  dfifo_pcie,
    IfShadow2Fifo.shadow    dshadow2fifo
    );
       
    // ----------------------------------------------------------------------------
    // PCIe DEFINES AND WIRES
    // ----------------------------------------------------------------------------
    
    IfPCIeSignals           ctx();
    IfPCIeTlpRxTx           tlp_tx();
    IfPCIeTlpRxTx           tlp_rx();
    IfAXIS128               tlps_tx();
    IfAXIS128               tlps_rx();
    
    IfAXIS128               tlps_static();       // static tlp transmit from cfg->tlp
    wire [15:0]             pcie_id;
    wire                    user_lnk_up;
    
    // system interface
    wire pcie_clk_c;
    wire clk_pcie;
    wire rst_pcie_user;                 // core user reset (PERST, link down); clk_pcie, registered in the IP

    // ----------------------------------------------------------------------------
    // RESETS - one per clock domain (see pcileech_pcie_a7_rst below).
    // ----------------------------------------------------------------------------
    wire rst_pcie_n;                    // -> core sys_rst_n
    wire rst_subsys_sys;                // clk_sys subsystem reset + clk_sys<->clk_pcie FIFO rst
    wire rst_subsys;                    // clk_pcie subsystem reset
    wire rst_clkpcie;                   // rst in clk_pcie
    wire rst_cfgword;                   // clk_sys: clears the control-word delivery gate
    wire cfgword_synced;

    pcileech_pcie_a7_rst i_pcileech_pcie_a7_rst(
        .clk_sys            ( clk_sys                   ),
        .clk_pcie           ( clk_pcie                  ),
        .rst                ( rst                       ),
        .pcie_perst_n       ( pcie_perst_n              ),
        .pcie_rst_core      ( dfifo_pcie.pcie_rst_core  ),
        .pcie_rst_subsys    ( dfifo_pcie.pcie_rst_subsys ),
        .cfgword_synced     ( cfgword_synced            ),
        .rst_pcie_user      ( rst_pcie_user             ),
        .rst_pcie_n         ( rst_pcie_n                ),
        .rst_subsys_sys     ( rst_subsys_sys            ),
        .rst_subsys         ( rst_subsys                ),
        .rst_clkpcie        ( rst_clkpcie               ),
        .rst_cfgword        ( rst_cfgword               )
    );

    // ----------------------------------------------------------------------------
    // SHADOW/BAR/FILTER CONTROL WORD clk_sys -> clk_pcie
    // The six bits change together on host writes, so they cross as one
    // coherent word through a handshake, never bit by bit.
    // rst_src (rst_cfgword) covers every reset that releases the clk_pcie
    // consumers: rst, host subsystem reset, core reset, and - through a
    // request/ack handshake in pcileech_pcie_a7_rst - the core user reset. After
    // any of them the consumers again wait for the word current at release.
    // ----------------------------------------------------------------------------
    wire pcie_cfgtlp_en, pcie_cfgtlp_zero, pcie_cfgtlp_filter, pcie_bar_en, pcie_cfgtlp_wren, pcie_alltlp_filter;

    pcileech_pcie_cfgword_cdc i_pcileech_pcie_cfgword_cdc(
        .clk_src            ( clk_sys                   ),
        .rst_src            ( rst_cfgword               ),
        .src_word           ( { dshadow2fifo.alltlp_filter, dshadow2fifo.cfgtlp_wren, dshadow2fifo.bar_en,
                                dshadow2fifo.cfgtlp_filter, dshadow2fifo.cfgtlp_zero, dshadow2fifo.cfgtlp_en } ),
        .src_synced         ( cfgword_synced            ),
        .clk_dst            ( clk_pcie                  ),
        .dst_word           ( { pcie_alltlp_filter, pcie_cfgtlp_wren, pcie_bar_en,
                                pcie_cfgtlp_filter, pcie_cfgtlp_zero, pcie_cfgtlp_en } )
    );

    // Buffer for differential system clock
    IBUFDS_GTE2 refclk_ibuf (.O(pcie_clk_c), .ODIV2(), .I(pcie_clk_p), .CEB(1'b0), .IB(pcie_clk_n));
    
    // ----------------------------------------------------
    // TickCount64 PCIe REFCLK and LED OUTPUT
    // ----------------------------------------------------

    time tickcount64_pcie_refclk = 0;
    always @ ( posedge pcie_clk_c )
        tickcount64_pcie_refclk <= tickcount64_pcie_refclk + 1;
    assign led_state = user_lnk_up || tickcount64_pcie_refclk[25];
    
    // ----------------------------------------------------------------------------
    // PCIe CFG RX/TX <--> FIFO below
    // ----------------------------------------------------------------------------
    
    pcileech_pcie_cfg_a7 i_pcileech_pcie_cfg_a7(
        .rst                        ( rst_subsys                ),
        .rst_sys                    ( rst_subsys_sys            ),
        .clk_sys                    ( clk_sys                   ),
        .clk_pcie                   ( clk_pcie                  ),
        .dfifo                      ( dfifo_cfg                 ),        
        .ctx                        ( ctx                       ),
        .tlps_static                ( tlps_static.source        ),
        .pcie_id                    ( pcie_id                   )   // -> [15:0]
    );
    
    // ----------------------------------------------------------------------------
    // PCIe TLP RX/TX <--> FIFO below
    // ----------------------------------------------------------------------------
    
    pcileech_tlps128_src64 i_pcileech_tlps128_src64(
        .rst                        ( rst_subsys                ),
        .clk_pcie                   ( clk_pcie                  ),
        .tlp_rx                     ( tlp_rx.sink               ),
        .tlps_out                   ( tlps_rx.source_lite       )
    );
    
    pcileech_pcie_tlp_a7 i_pcileech_pcie_tlp_a7(
        .rst                        ( rst_subsys                ),
        .rst_sys                    ( rst_subsys_sys            ),
        .clk_pcie                   ( clk_pcie                  ),
        .clk_sys                    ( clk_sys                   ),
        .cfgtlp_en                  ( pcie_cfgtlp_en            ),
        .cfgtlp_zero                ( pcie_cfgtlp_zero          ),
        .cfgtlp_filter              ( pcie_cfgtlp_filter        ),
        .bar_en                     ( pcie_bar_en               ),
        .cfgtlp_wren                ( pcie_cfgtlp_wren          ),
        .alltlp_filter              ( pcie_alltlp_filter        ),
        .dfifo                      ( dfifo_tlp                 ),
        .tlps_tx                    ( tlps_tx.source            ),       
        .tlps_rx                    ( tlps_rx.sink_lite         ),
        .tlps_static                ( tlps_static.sink          ),
        .dshadow2fifo               ( dshadow2fifo              ),
        .pcie_id                    ( pcie_id                   ),   // <- [15:0]
        .pcie_ctx                   ( ctx                       ),
        .rst_pcie_user              ( rst_pcie_user             )
    );
    
    // TX stream converter reset: global rst, and the core user reset (PERST#,
    // link down, core reset). The core drops its transmit interface then, so a
    // queued beat or the retained upper half of a beat must not reach the new
    // link session. Both terms are clk_pcie registers (synchronous reset).
    // The host subsystem reset (pcie_rst_subsys) on a live link deliberately
    // does not flush it: the upstream TX mux resets mid-packet then, so that
    // case needs a packet-boundary policy (see pcileech_tlps128_dst64).
    pcileech_tlps128_dst64 i_pcileech_tlps128_dst64(
        .rst                        ( rst_clkpcie || rst_pcie_user ),
        .clk_pcie                   ( clk_pcie                  ),
        .tlp_tx                     ( tlp_tx.source             ),
        .tlps_in                    ( tlps_tx.sink              )
    );
    
    // ----------------------------------------------------------------------------
    // PCIe CORE BELOW
    // ---------------------------------------------------------------------------- 
      
    pcie_7x_0 i_pcie_7x_0 (
        // pcie_7x_mgt
        .pci_exp_txp                ( pcie_tx_p                 ),  // ->
        .pci_exp_txn                ( pcie_tx_n                 ),  // ->
        .pci_exp_rxp                ( pcie_rx_p                 ),  // <-
        .pci_exp_rxn                ( pcie_rx_n                 ),  // <-
        .sys_clk                    ( pcie_clk_c                ),  // <-
        .sys_rst_n                  ( rst_pcie_n                ),  // <-
    
        // s_axis_tx (transmit data)
        .s_axis_tx_tdata            ( tlp_tx.data               ),  // <- [63:0]
        .s_axis_tx_tkeep            ( tlp_tx.keep               ),  // <- [7:0]
        .s_axis_tx_tlast            ( tlp_tx.last               ),  // <-
        .s_axis_tx_tready           ( tlp_tx.ready              ),  // ->
        .s_axis_tx_tuser            ( 4'b0                      ),  // <- [3:0]
        .s_axis_tx_tvalid           ( tlp_tx.valid              ),  // <-
    
        // s_axis_rx (receive data)
        .m_axis_rx_tdata            ( tlp_rx.data               ),  // -> [63:0]
        .m_axis_rx_tkeep            ( tlp_rx.keep               ),  // -> [7:0]
        .m_axis_rx_tlast            ( tlp_rx.last               ),  // -> 
        .m_axis_rx_tready           ( tlp_rx.ready              ),  // <-
        .m_axis_rx_tuser            ( tlp_rx.user               ),  // -> [21:0]
        .m_axis_rx_tvalid           ( tlp_rx.valid              ),  // ->
    
        // pcie_cfg_mgmt
        .cfg_mgmt_dwaddr            ( ctx.cfg_mgmt_dwaddr       ),  // <- [9:0]
        .cfg_mgmt_byte_en           ( ctx.cfg_mgmt_byte_en      ),  // <- [3:0]
        .cfg_mgmt_do                ( ctx.cfg_mgmt_do           ),  // -> [31:0]
        .cfg_mgmt_rd_en             ( ctx.cfg_mgmt_rd_en        ),  // <-
        .cfg_mgmt_rd_wr_done        ( ctx.cfg_mgmt_rd_wr_done   ),  // ->
        .cfg_mgmt_wr_readonly       ( ctx.cfg_mgmt_wr_readonly  ),  // <-
        .cfg_mgmt_wr_rw1c_as_rw     ( ctx.cfg_mgmt_wr_rw1c_as_rw ), // <-
        .cfg_mgmt_di                ( ctx.cfg_mgmt_di           ),  // <- [31:0]
        .cfg_mgmt_wr_en             ( ctx.cfg_mgmt_wr_en        ),  // <-

        // Unused inputs tied inactive. Left unconnected, the IP's driverless
        // nets fail opt_design (Opt31-67) under Vivado 2026.1.
        // flow control: select 3'b000; fc_* outputs are unused.
        .fc_sel                     ( 3'b000                    ),  // <- [2:0]
        // error reporting: no user-reported errors. These are active-high
        // requests; header/log values are sampled only with a request.
        .cfg_err_ecrc               ( 1'b0                      ),  // <-
        .cfg_err_ur                 ( 1'b0                      ),  // <-
        .cfg_err_cpl_timeout        ( 1'b0                      ),  // <-
        .cfg_err_cpl_unexpect       ( 1'b0                      ),  // <-
        .cfg_err_cpl_abort          ( 1'b0                      ),  // <-
        .cfg_err_posted             ( 1'b0                      ),  // <-
        .cfg_err_cor                ( 1'b0                      ),  // <-
        .cfg_err_atomic_egress_blocked ( 1'b0                   ),  // <-
        .cfg_err_internal_cor       ( 1'b0                      ),  // <-
        .cfg_err_malformed          ( 1'b0                      ),  // <-
        .cfg_err_mc_blocked         ( 1'b0                      ),  // <-
        .cfg_err_poisoned           ( 1'b0                      ),  // <-
        .cfg_err_norecovery         ( 1'b0                      ),  // <-
        .cfg_err_locked             ( 1'b0                      ),  // <-
        .cfg_err_acs                ( 1'b0                      ),  // <-
        .cfg_err_internal_uncor     ( 1'b0                      ),  // <-
        .cfg_err_tlp_cpl_header     ( 48'h0                     ),  // <- [47:0]
        .cfg_err_aer_headerlog      ( 128'h0                    ),  // <- [127:0]
        .cfg_aer_interrupt_msgnum   ( 5'b00000                  ),  // <- [4:0]

        // special core config
        //.pcie_cfg_vend_id           ( dfifo_pcie.pcie_cfg_vend_id       ),  // <- [15:0]
        //.pcie_cfg_dev_id            ( dfifo_pcie.pcie_cfg_dev_id        ),  // <- [15:0]
        //.pcie_cfg_rev_id            ( dfifo_pcie.pcie_cfg_rev_id        ),  // <- [7:0]
        //.pcie_cfg_subsys_vend_id    ( dfifo_pcie.pcie_cfg_subsys_vend_id ), // <- [15:0]
        //.pcie_cfg_subsys_id         ( dfifo_pcie.pcie_cfg_subsys_id     ),  // <- [15:0]
    
        // pcie2_cfg_interrupt
        .cfg_interrupt_assert       ( ctx.cfg_interrupt_assert          ),  // <-
        .cfg_interrupt              ( ctx.cfg_interrupt                 ),  // <-
        .cfg_interrupt_mmenable     ( ctx.cfg_interrupt_mmenable        ),  // -> [2:0]
        .cfg_interrupt_msienable    ( ctx.cfg_interrupt_msienable       ),  // ->
        .cfg_interrupt_msixenable   ( ctx.cfg_interrupt_msixenable      ),  // ->
        .cfg_interrupt_msixfm       ( ctx.cfg_interrupt_msixfm          ),  // ->
        .cfg_pciecap_interrupt_msgnum ( ctx.cfg_pciecap_interrupt_msgnum ), // <- [4:0]
        .cfg_interrupt_rdy          ( ctx.cfg_interrupt_rdy             ),  // ->
        .cfg_interrupt_do           ( ctx.cfg_interrupt_do              ),  // -> [7:0]
        .cfg_interrupt_stat         ( ctx.cfg_interrupt_stat            ),  // <-
        .cfg_interrupt_di           ( ctx.cfg_interrupt_di              ),  // <- [7:0]
        
        // pcie2_cfg_control
        .cfg_ds_bus_number          ( ctx.cfg_bus_number                ),  // <- [7:0]
        .cfg_ds_device_number       ( ctx.cfg_device_number             ),  // <- [4:0]
        .cfg_ds_function_number     ( ctx.cfg_function_number           ),  // <- [2:0]
        .cfg_dsn                    ( ctx.cfg_dsn                       ),  // <- [63:0]
        .cfg_pm_force_state         ( ctx.cfg_pm_force_state            ),  // <- [1:0]
        .cfg_pm_force_state_en      ( ctx.cfg_pm_force_state_en         ),  // <-
        .cfg_pm_halt_aspm_l0s       ( ctx.cfg_pm_halt_aspm_l0s          ),  // <-
        .cfg_pm_halt_aspm_l1        ( ctx.cfg_pm_halt_aspm_l1           ),  // <-
        .cfg_pm_send_pme_to         ( ctx.cfg_pm_send_pme_to            ),  // <-
        .cfg_pm_wake                ( ctx.cfg_pm_wake                   ),  // <-
        .rx_np_ok                   ( ctx.rx_np_ok                      ),  // <-
        .rx_np_req                  ( ctx.rx_np_req                     ),  // <-
        .cfg_trn_pending            ( ctx.cfg_trn_pending               ),  // <-
        .cfg_turnoff_ok             ( ctx.cfg_turnoff_ok                ),  // <-
        .tx_cfg_gnt                 ( ctx.tx_cfg_gnt                    ),  // <-
        
        // pcie2_cfg_status
        .cfg_command                ( ctx.cfg_command                   ),  // -> [15:0]
        .cfg_bus_number             ( ctx.cfg_bus_number                ),  // -> [7:0]
        .cfg_device_number          ( ctx.cfg_device_number             ),  // -> [4:0]
        .cfg_function_number        ( ctx.cfg_function_number           ),  // -> [2:0]
        .cfg_root_control_pme_int_en( ctx.cfg_root_control_pme_int_en   ),  // ->
        .cfg_bridge_serr_en         ( ctx.cfg_bridge_serr_en            ),  // ->
        .cfg_dcommand               ( ctx.cfg_dcommand                  ),  // -> [15:0]
        .cfg_dcommand2              ( ctx.cfg_dcommand2                 ),  // -> [15:0]
        .cfg_dstatus                ( ctx.cfg_dstatus                   ),  // -> [15:0]
        .cfg_lcommand               ( ctx.cfg_lcommand                  ),  // -> [15:0]
        .cfg_lstatus                ( ctx.cfg_lstatus                   ),  // -> [15:0]
        .cfg_pcie_link_state        ( ctx.cfg_pcie_link_state           ),  // -> [2:0]
        .cfg_pmcsr_pme_en           ( ctx.cfg_pmcsr_pme_en              ),  // ->
        .cfg_pmcsr_pme_status       ( ctx.cfg_pmcsr_pme_status          ),  // ->
        .cfg_pmcsr_powerstate       ( ctx.cfg_pmcsr_powerstate          ),  // -> [1:0]
        .cfg_received_func_lvl_rst  ( ctx.cfg_received_func_lvl_rst     ),  // ->
        .cfg_status                 ( ctx.cfg_status                    ),  // -> [15:0]
        .cfg_to_turnoff             ( ctx.cfg_to_turnoff                ),  // ->
        .tx_buf_av                  ( ctx.tx_buf_av                     ),  // -> [5:0]
        .tx_cfg_req                 ( ctx.tx_cfg_req                    ),  // ->
        .tx_err_drop                ( ctx.tx_err_drop                   ),  // ->
        .cfg_vc_tcvc_map            ( ctx.cfg_vc_tcvc_map               ),  // -> [6:0]
        .cfg_aer_rooterr_corr_err_received          ( ctx.cfg_aer_rooterr_corr_err_received             ),  // ->
        .cfg_aer_rooterr_corr_err_reporting_en      ( ctx.cfg_aer_rooterr_corr_err_reporting_en         ),  // ->
        .cfg_aer_rooterr_fatal_err_received         ( ctx.cfg_aer_rooterr_fatal_err_received            ),  // ->
        .cfg_aer_rooterr_fatal_err_reporting_en     ( ctx.cfg_aer_rooterr_fatal_err_reporting_en        ),  // ->
        .cfg_aer_rooterr_non_fatal_err_received     ( ctx.cfg_aer_rooterr_non_fatal_err_received        ),  // ->
        .cfg_aer_rooterr_non_fatal_err_reporting_en ( ctx.cfg_aer_rooterr_non_fatal_err_reporting_en    ),  // ->
        .cfg_root_control_syserr_corr_err_en        ( ctx.cfg_root_control_syserr_corr_err_en           ),  // ->
        .cfg_root_control_syserr_fatal_err_en       ( ctx.cfg_root_control_syserr_fatal_err_en          ),  // ->
        .cfg_root_control_syserr_non_fatal_err_en   ( ctx.cfg_root_control_syserr_non_fatal_err_en      ),  // ->
        .cfg_slot_control_electromech_il_ctl_pulse  ( ctx.cfg_slot_control_electromech_il_ctl_pulse     ),  // ->
        
        // PCIe core PHY
        .pl_initial_link_width      ( ctx.pl_initial_link_width         ),  // -> [2:0]
        .pl_phy_lnk_up              ( ctx.pl_phy_lnk_up                 ),  // ->
        .pl_lane_reversal_mode      ( ctx.pl_lane_reversal_mode         ),  // -> [1:0]
        .pl_link_gen2_cap           ( ctx.pl_link_gen2_cap              ),  // ->
        .pl_link_partner_gen2_supported ( ctx.pl_link_partner_gen2_supported ),  // ->
        .pl_link_upcfg_cap          ( ctx.pl_link_upcfg_cap             ),  // ->
        .pl_sel_lnk_rate            ( ctx.pl_sel_lnk_rate               ),  // ->
        .pl_sel_lnk_width           ( ctx.pl_sel_lnk_width              ),  // -> [1:0]
        .pl_ltssm_state             ( ctx.pl_ltssm_state                ),  // -> [5:0]
        .pl_rx_pm_state             ( ctx.pl_rx_pm_state                ),  // -> [1:0]
        .pl_tx_pm_state             ( ctx.pl_tx_pm_state                ),  // -> [2:0]
        .pl_directed_change_done    ( ctx.pl_directed_change_done       ),  // ->
        .pl_received_hot_rst        ( ctx.pl_received_hot_rst           ),  // ->
        .pl_directed_link_auton     ( ctx.pl_directed_link_auton        ),  // <-
        .pl_directed_link_change    ( ctx.pl_directed_link_change       ),  // <- [1:0]
        .pl_directed_link_speed     ( ctx.pl_directed_link_speed        ),  // <-
        .pl_directed_link_width     ( ctx.pl_directed_link_width        ),  // <- [1:0]
        .pl_upstream_prefer_deemph  ( ctx.pl_upstream_prefer_deemph     ),  // <-
        .pl_transmit_hot_rst        ( ctx.pl_transmit_hot_rst           ),  // <-
        .pl_downstream_deemph_source( ctx.pl_downstream_deemph_source   ),  // <-
        
        // DRP - clock domain clk_100 - write should only happen when core is in reset state ...
        .pcie_drp_clk               ( clk_sys                           ),  // <-
        .pcie_drp_en                ( dfifo_pcie.drp_en                 ),  // <-
        .pcie_drp_we                ( dfifo_pcie.drp_we                 ),  // <-
        .pcie_drp_addr              ( dfifo_pcie.drp_addr               ),  // <- [8:0]
        .pcie_drp_di                ( dfifo_pcie.drp_di                 ),  // <- [15:0]
        .pcie_drp_rdy               ( dfifo_pcie.drp_rdy                ),  // ->
        .pcie_drp_do                ( dfifo_pcie.drp_do                 ),  // -> [15:0]
    
        // user interface
        .user_clk_out               ( clk_pcie                          ),  // ->
        .user_reset_out             ( rst_pcie_user                     ),  // ->
        .user_lnk_up                ( user_lnk_up                       ),  // ->
        .user_app_rdy               (                                   )   // ->
    );

endmodule


// ------------------------------------------------------------------------
// TLP STREAM SINK:
// Convert a 128-bit TLP-AXI-STREAM to a 64-bit PCIe core AXI-STREAM.
//
// rst (in pcileech_pcie_a7: rst or the core user reset) flushes the queue.
// KNOWN LIMITATION (inherited, not fixed here): the host subsystem reset
// (pcie_rst_subsys) on a live link does not reset this converter, while the
// upstream TX mux and sources do. Queued beats keep draining after it; if the
// subsystem reset cut a packet before its last beat was queued, the remaining
// words are never sent and the next packet follows the unterminated one.
// Resetting here as well would not fix that: it would drop the tail of a
// packet the core may already be transmitting. A correct soft reset needs a
// packet-boundary policy (finish or drop whole packets on both sides).
// ------------------------------------------------------------------------
module pcileech_tlps128_dst64(
    input                   rst,
    input                   clk_pcie,
    IfPCIeTlpRxTx.source    tlp_tx,
    IfAXIS128.sink          tlps_in
);
    // tlps_in is a pull stream: tready in one clock requests one 128-bit beat,
    // which arrives in the next clock and must be taken whatever tlp_tx.ready
    // is then. The PCIe core takes a 64-bit word only when valid && ready.
    // Beats therefore go through a two-entry queue, and a new beat is requested
    // only when a slot is guaranteed for it even if the core stalls. A stalled
    // word stays on tlp_tx unchanged until the core accepts it.
    bit [127:0] q_tdata [2];
    bit [3:0]   q_tkeepdw [2];
    bit         q_tlast [2];
    bit [1:0]   q_count = 0;
    bit         q_head  = 0;
    bit         q_upper = 0;     // the head beat's lower 64 bits were sent

    wire        h_upper_dws = q_tkeepdw[q_head][2];
    assign tlp_tx.valid = (q_count != 0);
    assign tlp_tx.data  = q_upper ? q_tdata[q_head][127:64] : q_tdata[q_head][63:0];
    assign tlp_tx.keep  = (q_upper ? q_tkeepdw[q_head][3] : q_tkeepdw[q_head][1]) ? 8'hff : 8'h0f;
    assign tlp_tx.last  = q_tlast[q_head] && (q_upper || !h_upper_dws);

    wire        fire    = tlp_tx.valid && tlp_tx.ready;
    wire        pop     = fire && (q_upper || !h_upper_dws);
    wire        push    = tlps_in.tvalid;
    wire [1:0]  q_count_next = q_count + push - pop;

    // A beat requested now arrives next clock: it needs a free slot even if
    // nothing is popped then.
    assign tlps_in.tready = !rst && (q_count_next <= 1);

    always @ ( posedge clk_pcie ) begin
        if ( rst ) begin
            q_count     <= 0;
            q_head      <= 0;
            q_upper     <= 0;
        end
        else begin
            if ( push ) begin
                q_tdata[q_head ^ q_count[0]]    <= tlps_in.tdata;
                q_tkeepdw[q_head ^ q_count[0]]  <= tlps_in.tkeepdw;
                q_tlast[q_head ^ q_count[0]]    <= tlps_in.tlast;
            end
            if ( pop ) begin
                q_head  <= ~q_head;
                q_upper <= 0;
            end
            else if ( fire ) begin
                q_upper <= 1;
            end
            q_count <= q_count_next;
        end
    end

endmodule


// ------------------------------------------------------------------------
// TLP STREAM SOURCE:
// Convert a 64-bit PCIe core AXIS to a 128-bit TLP-AXI-STREAM 
// ------------------------------------------------------------------------
module pcileech_tlps128_src64(
    input                   rst,
    input                   clk_pcie,
    IfPCIeTlpRxTx.sink      tlp_rx,
    IfAXIS128.source_lite   tlps_out
);

    bit [127:0] tdata;
    bit         first       = 1;
    bit         tlast       = 0;
    bit [3:0]   len         = 0;
    bit [6:0]   bar_hit     = 0;
    wire        tvalid      = tlast || (len>2);
    
    assign tlp_rx.ready     = 1'b1;
    assign tlps_out.tdata   = tdata;
    assign tlps_out.tkeepdw = {(len>3), (len>2), (len>1), 1'b1};
    assign tlps_out.tlast   = tlast;   
    assign tlps_out.tvalid  = tvalid; 
    assign tlps_out.tuser[0]    = first;
    assign tlps_out.tuser[1]    = tlast;
    assign tlps_out.tuser[8:2]  = bar_hit;
    
    wire [3:0]  next_base   = (tlast || tvalid) ? 0 : len;
    wire [3:0]  next_len    = next_base + 4'd1 + {3'd0, tlp_rx.keep[4]};

    always @ ( posedge clk_pcie )
        if ( rst ) begin
            first   <= 1;
            tlast   <= 0;
            len     <= 0;
            bar_hit <= 0;
        end
        else if ( tlp_rx.valid ) begin
            tdata[(32*next_base)+:64] <= tlp_rx.data;
            first   <= tvalid ? tlast : first;
            tlast   <= tlp_rx.last;
            len     <= next_len;
            bar_hit <= tlp_rx.user[8:2];
        end
        else if ( tvalid ) begin 
            first   <= tlast;
            tlast   <= 0;
            len     <= 0;
            bar_hit <= 0;
        end
    
endmodule



// ------------------------------------------------------------------------
// CONTROL WORD CLOCK DOMAIN CROSSING:
// Carry a multi-bit control word from clk_src to clk_dst as one coherent
// value through xpm_cdc_handshake. The destination only ever holds a word that
// existed in clk_src, so related bits never appear mixed. When the source
// changes while a transfer is in flight, the transfer completes and the
// newest value is sent next, so the destination converges on the latest word.
//
// The handshake is never aborted (xpm_cdc_handshake has no reset and requires
// src_send to stay high until src_rcv). rst_src only clears src_synced, which
// rises again once the word current after reset has been delivered and is
// meant to hold the clk_dst consumers in reset until then. rst_src must
// include every reset that releases those consumers (in pcileech_pcie_a7:
// rst_cfgword of pcileech_pcie_a7_rst). dst_word has no
// reset: it always holds the last delivered word. Its power-up value matches
// the FIFO's RW reset defaults but is never relied on, because src_synced
// starts low.
// ------------------------------------------------------------------------
module pcileech_pcie_cfgword_cdc #(
    parameter               WIDTH       = 6,
    parameter [WIDTH-1:0]   INIT_WORD   = 6'b001111     // {alltlp_filter, cfgtlp_wren, bar_en, cfgtlp_filter, cfgtlp_zero, cfgtlp_en}
) (
    input                   clk_src,
    input                   rst_src,        // clk_src synchronous
    input   [WIDTH-1:0]     src_word,
    output reg              src_synced = 1'b0,
    input                   clk_dst,
    output reg [WIDTH-1:0]  dst_word = INIT_WORD
);
    localparam [1:0] S_IDLE = 2'd0, S_LOAD = 2'd1, S_SEND = 2'd2, S_DRAIN = 2'd3;

    reg [1:0]       state       = S_IDLE;
    reg             src_send    = 1'b0;
    reg [WIDTH-1:0] tx_word     = INIT_WORD;    // held from S_LOAD until back in S_IDLE
    reg [WIDTH-1:0] acked_word  = INIT_WORD;    // last word the destination received
    reg             acked_valid = 1'b0;
    wire            src_rcv;
    wire            dest_req;
    wire [WIDTH-1:0] dest_out;

    wire            delivered   = (state == S_IDLE) && acked_valid && (acked_word == src_word);

    always @ ( posedge clk_src ) begin
        case ( state )
            S_IDLE:
                if ( !src_rcv && !delivered ) begin
                    tx_word     <= src_word;
                    state       <= S_LOAD;
                end
            S_LOAD: begin                       // tx_word stable for a clock before src_send
                src_send    <= 1'b1;
                state       <= S_SEND;
            end
            S_SEND:
                if ( src_rcv ) begin
                    src_send    <= 1'b0;
                    acked_word  <= tx_word;
                    acked_valid <= 1'b1;
                    state       <= S_DRAIN;
                end
            S_DRAIN:                            // src_rcv must fall before the next src_send
                if ( !src_rcv )
                    state       <= S_IDLE;
            default:                            // unreachable: all four encodings are states
                state       <= S_IDLE;
        endcase
        if ( rst_src )
            src_synced <= 1'b0;
        else if ( delivered )
            src_synced <= 1'b1;
    end

    xpm_cdc_handshake #(
        .DEST_EXT_HSK       ( 0                     ),
        .DEST_SYNC_FF       ( 4                     ),
        .INIT_SYNC_FF       ( 0                     ),
        .SIM_ASSERT_CHK     ( 0                     ),
        .SRC_SYNC_FF        ( 4                     ),
        .WIDTH              ( WIDTH                 )
    ) i_xpm_cdc_handshake (
        .src_clk            ( clk_src               ),
        .src_in             ( tx_word               ),
        .src_send           ( src_send              ),
        .src_rcv            ( src_rcv               ),
        .dest_clk           ( clk_dst               ),
        .dest_out           ( dest_out              ),
        .dest_req           ( dest_req              ),
        .dest_ack           ( 1'b0                  )
    );

    always @ ( posedge clk_dst )
        if ( dest_req )
            dst_word <= dest_out;

endmodule



// ------------------------------------------------------------------------
// PCIe RESETS:
// One reset per clock domain, created at the domain boundary. rst,
// pcie_perst_n, pcie_rst_core and pcie_rst_subsys are clk_sys registers or
// synchronizer outputs. A reset entering clk_pcie is asserted asynchronously
// (it holds while clk_pcie is stopped) and released synchronously to
// clk_pcie. No reset is a combinational mix of clock domains, and no LUT
// drives an asynchronous reset pin.
// ------------------------------------------------------------------------
module pcileech_pcie_a7_rst(
    input                   clk_sys,
    input                   clk_pcie,
    input                   rst,                // clk_sys
    input                   pcie_perst_n,       // clk_sys (synchronized PERST#)
    input                   pcie_rst_core,      // clk_sys
    input                   pcie_rst_subsys,    // clk_sys
    input                   cfgword_synced,     // clk_sys: post-reset control word delivered to clk_pcie
    input                   rst_pcie_user,      // clk_pcie: core user reset (registered in the IP)
    output reg              rst_pcie_n = 1'b0,  // core sys_rst_n
    output reg              rst_subsys_sys = 1'b1,
    output                  rst_subsys,
    output                  rst_clkpcie,
    output                  rst_cfgword         // clk_sys: rst_src of pcileech_pcie_cfgword_cdc
);
    // PCIe core sys_rst_n: one active-low clk_sys register, so the core's own
    // reset synchronizer never sees a decode glitch or a LUT.
    // PG054 (System Interface): sys_rst_n must be asserted for at least
    // 1500 ns on power-on and warm reset. A reset source may be a single
    // clk_sys cycle (pcie_rst_core is a host-written register bit), so the
    // assertion is stretched: rst_pcie_n is released only after
    // RST_PCIE_N_CYCLES consecutive clk_sys cycles with no reset source.
    // clk_sys is the 100 MHz board clock (XDC net_clk, 10.000 ns, used without
    // an MMCM), so the 256 cycles give at least 2560 ns. That still meets
    // 1500 ns if clk_sys were up to 170 MHz. Every new source assertion
    // restarts the full stretch. At power-up the counter starts at 0, so
    // the stretch applies then too. A source held low (for example PERST#)
    // keeps sys_rst_n low indefinitely. The counter runs on clk_sys only; it
    // never waits for a PCIe-core-generated clock.
    // Assertion still takes effect one clk_sys edge after a source asserts,
    // as before.
    localparam integer RST_PCIE_N_LOG2 = 8;         // RST_PCIE_N_CYCLES = 2**8 = 256
    reg  [RST_PCIE_N_LOG2:0] rst_pcie_n_cnt = '0;   // clk_sys cycles since the last reset source; MSB = done
    wire rst_pcie_src = rst || ~pcie_perst_n || pcie_rst_core;
    always @ ( posedge clk_sys ) begin
        if ( rst_pcie_src )
            rst_pcie_n_cnt <= '0;
        else if ( !rst_pcie_n_cnt[RST_PCIE_N_LOG2] )
            rst_pcie_n_cnt <= rst_pcie_n_cnt + 1'b1;
        rst_pcie_n <= rst_pcie_n_cnt[RST_PCIE_N_LOG2] && !rst_pcie_src;
    end

    // ------------------------------------------------------------------------
    // Core user reset -> control-word gate re-arm (request/ack handshake).
    // The core user reset may be a single clk_pcie pulse, may happen while
    // clk_sys is slower, and is released in clk_pcie. After it, the clk_pcie
    // consumers must again wait for the control word current at (or after)
    // its release. clk_pcie latches the event in ua_busy and keeps rst_subsys
    // asserted itself until clk_sys has acknowledged that the gate is re-armed
    // (cfgword_synced cleared and rst_subsys_req set), so there is no clock
    // edge on which rst_subsys is released in between.
    //   clk_pcie: IDLE (ua_busy=0) -user reset-> REQ (ua_req=1)
    //             REQ  -ack seen, user reset released, rst_subsys_req_pcie
    //                   seen asserted-> DROP (ua_req=0)
    //             DROP -ack gone-> IDLE, or REQ if a user reset came meanwhile.
    //   clk_sys:  ua_req_sys clears the gate (rst_cfgword) and sets
    //             rst_subsys_req; ua_ack follows one clock later, once both
    //             have taken effect. While ua_req_sys stays high the gate stays
    //             cleared, so it is re-armed after the user reset was released
    //             (REQ->DROP needs the user reset low).
    // Four-phase: a new request is raised only after the previous ack has
    // fallen, so a stale ack is never taken for a new one. ua_* are not reset:
    // like the control-word handshake, this one is never aborted.
    // The request is dropped only once rst_subsys_req_pcie has been seen
    // asserted in clk_pcie. Otherwise the drop would rely on the asynchronous
    // assertion of rst_subsys_req_pcie (an untimed preset path) arriving before
    // the ack round trip completes. With the guard, ua_busy never falls while
    // the gate's reset has not yet reached clk_pcie. No deadlock: while ua_req
    // is high, ua_req_sys pins rst_subsys_req high (rst_cfgword), and its
    // asynchronous preset holds rst_subsys_req_pcie high regardless of clocks,
    // so the guard is true whenever the ack is. A late or metastable sample of
    // a 0->1 edge only delays the drop by a clk_pcie cycle.
    // ------------------------------------------------------------------------
    reg  ua_req  = 1'b0;                // clk_pcie: re-arm request
    reg  ua_busy = 1'b0;                // clk_pcie: REQ or DROP
    reg  ua_pend = 1'b0;                // clk_pcie: user reset seen during DROP
    wire ua_req_sys;                    // clk_sys
    reg  ua_ack  = 1'b0;                // clk_sys
    wire ua_ack_pcie;                   // clk_pcie
    wire rst_subsys_req_pcie;           // clk_pcie (async assert, sync release)

    always @ ( posedge clk_pcie )
        if ( !ua_busy ) begin                               // IDLE
            ua_req  <= rst_pcie_user;
            ua_busy <= rst_pcie_user;
            ua_pend <= 1'b0;
        end
        else if ( ua_req ) begin                            // REQ
            if ( ua_ack_pcie && !rst_pcie_user && rst_subsys_req_pcie )
                ua_req  <= 1'b0;
        end
        else if ( !ua_ack_pcie ) begin                      // DROP, ack gone
            ua_req  <= ua_pend || rst_pcie_user;
            ua_busy <= ua_pend || rst_pcie_user;
            ua_pend <= 1'b0;
        end
        else                                                // DROP
            ua_pend <= ua_pend || rst_pcie_user;

    xpm_cdc_single #(
        .DEST_SYNC_FF       ( 4                     ),
        .INIT_SYNC_FF       ( 0                     ),
        .SIM_ASSERT_CHK     ( 0                     ),
        .SRC_INPUT_REG      ( 0                     )   // ua_req is a register
    ) i_cdc_ua_req (
        .src_clk            ( clk_pcie              ),
        .src_in             ( ua_req                ),
        .dest_clk           ( clk_sys               ),
        .dest_out           ( ua_req_sys            )
    );

    // Control-word gate clear: every reset that releases the clk_pcie
    // consumers. PERST# and the core reset are also taken directly here, not
    // only through the core user reset they cause. All terms are clk_sys
    // registers or synchronizer outputs; synchronous clear only.
    assign rst_cfgword = rst || ~pcie_perst_n || pcie_rst_core || pcie_rst_subsys || ua_req_sys;

    // Subsystem reset, clk_pcie side. The clk_sys request also stays asserted
    // until the control word has delivered its post-reset value, so clk_pcie
    // logic never leaves reset on a stale shadow/BAR/filter setting.
    reg  rst_subsys_req = 1'b1;
    always @ ( posedge clk_sys )
        rst_subsys_req <= rst_cfgword || ~cfgword_synced;

    // Ack only after the request has registered rst_subsys_req (and, at the
    // same edge, cleared cfgword_synced through rst_cfgword).
    always @ ( posedge clk_sys )
        ua_ack <= ua_req_sys && rst_subsys_req;

    xpm_cdc_single #(
        .DEST_SYNC_FF       ( 4                     ),
        .INIT_SYNC_FF       ( 0                     ),
        .SIM_ASSERT_CHK     ( 0                     ),
        .SRC_INPUT_REG      ( 0                     )   // ua_ack is a register
    ) i_cdc_ua_ack (
        .src_clk            ( clk_sys               ),
        .src_in             ( ua_ack                ),
        .dest_clk           ( clk_pcie              ),
        .dest_out           ( ua_ack_pcie           )
    );

    xpm_cdc_async_rst #(
        .DEST_SYNC_FF       ( 4                     ),
        .INIT_SYNC_FF       ( 0                     ),
        .RST_ACTIVE_HIGH    ( 1                     )
    ) i_cdc_rst_subsys_pcie (
        .src_arst           ( rst_subsys_req        ),
        .dest_clk           ( clk_pcie              ),
        .dest_arst          ( rst_subsys_req_pcie   )
    );
    // All terms are clk_pcie registers; used only as a synchronous reset.
    // ua_busy covers the core user reset from its release until clk_sys has
    // re-armed the control-word gate (rst_subsys_req_pcie is asserted by then).
    assign rst_subsys = rst_subsys_req_pcie || rst_pcie_user || ua_busy;

    // Registered copy of rst_subsys: asserted asynchronously with the request,
    // follows the core user reset synchronously. Glitch-free source for the
    // crossing back into clk_sys.
    reg  rst_subsys_pcie_q = 1'b1;
    always @ ( posedge clk_pcie or posedge rst_subsys_req_pcie )
        if ( rst_subsys_req_pcie )
            rst_subsys_pcie_q <= 1'b1;
        else
            rst_subsys_pcie_q <= rst_pcie_user || ua_busy;

    wire rst_subsys_pcie_sys;
    xpm_cdc_async_rst #(
        .DEST_SYNC_FF       ( 4                     ),
        .INIT_SYNC_FF       ( 0                     ),
        .RST_ACTIVE_HIGH    ( 1                     )
    ) i_cdc_rst_subsys_sys (
        .src_arst           ( rst_subsys_pcie_q     ),
        .dest_clk           ( clk_sys               ),
        .dest_arst          ( rst_subsys_pcie_sys   )
    );

    // Subsystem reset, clk_sys side: clk_sys logic and the asynchronous rst
    // pins of the clk_sys<->clk_pcie FIFOs (one register, no LUT on the pin).
    // It asserts with any reset source and is released only after the
    // clk_pcie side has left reset (core user reset included), so clk_pcie
    // state such as the TX packet count is never released after the FIFOs.
    always @ ( posedge clk_sys )
        rst_subsys_sys <= rst || pcie_rst_subsys || rst_subsys_pcie_sys;

    // rst alone in clk_pcie (with the core user reset: the TX stream converter).
    xpm_cdc_async_rst #(
        .DEST_SYNC_FF       ( 4                     ),
        .INIT_SYNC_FF       ( 0                     ),
        .RST_ACTIVE_HIGH    ( 1                     )
    ) i_cdc_rst_clkpcie (
        .src_arst           ( rst                   ),
        .dest_clk           ( clk_pcie              ),
        .dest_arst          ( rst_clkpcie           )
    );

endmodule
