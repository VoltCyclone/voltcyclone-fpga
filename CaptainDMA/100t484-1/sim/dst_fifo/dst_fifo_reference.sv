// Frozen reference: pcileech_tlps128_dst_fifo at board e210d72 (FIFO block-RAM
// output straight to the mux ports), renamed for lockstep comparison against the
// prefetching version in tb_dst_mux.sv. Do not edit.
`timescale 1ns / 1ps
`include "pcileech_header.svh"
module pcileech_tlps128_dst_fifo_ref(
    input                   rst,            // clk_sys register: FIFO rst
    input                   clk_pcie,
    input                   clk_sys,
    IfAXIS128.sink_lite     tlps_in,
    IfPCIeFifoTlp.mp_pcie   dfifo
);

    wire         tvalid;
    wire         fifo_valid;
    wire         fifo_full;
    wire [127:0] tdata;
    wire [3:0]   tkeepdw;
    wire         tlast;
    wire         first;

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
    //   FIFO is accessible and not full;
    // - beats of a TLP whose first beat was not admitted are dropped;
    // - if a beat of an admitted TLP is refused (FIFO reset or full), the rest
    //   of that TLP is dropped, so no suffix is ever written without its head.
    //   A reset flushes the head too. If the FIFO instead fills up inside a
    //   TLP (host not draining; not a reset case), the head stays in the FIFO
    //   without its last beat, as before this change.
    bit          rx_admit = 0;  // current RX TLP is being written
    wire         rx_pass  = tlps_in.tuser[0] ? (acc_pcie && !fifo_full) : (rx_admit && acc_pcie && !fifo_full);
    always @ ( posedge clk_pcie )
        if ( !acc_pcie )
            rx_admit <= 1'b0;
        else if ( tlps_in.tvalid )
            rx_admit <= rx_pass && !tlps_in.tlast;

    fifo_134_134_clk2 i_fifo_134_134_clk2 (
        .rst        ( rst               ),
        .wr_clk     ( clk_pcie          ),
        .rd_clk     ( clk_sys           ),
        .din        ( { tlps_in.tuser[0], tlps_in.tlast, tlps_in.tkeepdw, tlps_in.tdata } ),
        .wr_en      ( tlps_in.tvalid && rx_pass ),
        .rd_en      ( dfifo.rx_rd_en && acc_sys ),
        .dout       ( { first, tlast, tkeepdw, tdata } ),
        .full       ( fifo_full         ),
        .empty      (                   ),
        .valid      ( fifo_valid        )
    );
    assign tvalid = fifo_valid && acc_sys;

    assign dfifo.rx_data[0]  = tdata[31:0];
    assign dfifo.rx_data[1]  = tdata[63:32];
    assign dfifo.rx_data[2]  = tdata[95:64];
    assign dfifo.rx_data[3]  = tdata[127:96];
    assign dfifo.rx_first[0] = first;
    assign dfifo.rx_first[1] = 0;
    assign dfifo.rx_first[2] = 0;
    assign dfifo.rx_first[3] = 0;
    assign dfifo.rx_last[0]  = tlast && (tkeepdw == 4'b0001);
    assign dfifo.rx_last[1]  = tlast && (tkeepdw == 4'b0011);
    assign dfifo.rx_last[2]  = tlast && (tkeepdw == 4'b0111);
    assign dfifo.rx_last[3]  = tlast && (tkeepdw == 4'b1111);
    assign dfifo.rx_valid[0] = tvalid && tkeepdw[0];
    assign dfifo.rx_valid[1] = tvalid && tkeepdw[1];
    assign dfifo.rx_valid[2] = tvalid && tkeepdw[2];
    assign dfifo.rx_valid[3] = tvalid && tkeepdw[3];

endmodule
