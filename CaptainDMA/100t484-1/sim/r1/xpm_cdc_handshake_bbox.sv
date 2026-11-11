// Port-only xpm_cdc_handshake declaration for Verilator lint (not simulated).
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off DECLFILENAME */
(* blackbox *) module xpm_cdc_handshake #(parameter integer DEST_EXT_HSK=1, DEST_SYNC_FF=4, INIT_SYNC_FF=0, SIM_ASSERT_CHK=0, SRC_SYNC_FF=4, WIDTH=1)
    (input src_clk, input [WIDTH-1:0] src_in, input src_send, output src_rcv,
     input dest_clk, output [WIDTH-1:0] dest_out, output dest_req, input dest_ack);
endmodule
/* verilator lint_on DECLFILENAME */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
