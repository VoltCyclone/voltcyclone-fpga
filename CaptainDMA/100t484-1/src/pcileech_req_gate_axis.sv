// IfAXIS128 adapter for the R1 gate at the merged-TX -> dst64 boundary.
// The core has flat ports so the same behavior is testable with Icarus.
`timescale 1ns / 1ps
/* verilator lint_off DECLFILENAME */
`include "pcileech_header.svh"
/* verilator lint_on DECLFILENAME */

module pcileech_req_gate_axis #(parameter integer N_NP_MAX = 0) (
    input clk, rst,
    IfAXIS128.sink tlps_in,
    IfAXIS128.source tlps_out,
    input [15:0] live_rid,
    input bme,
    input [2:0] mrrs_code,
    input ext_tag_en,
    input [255:0] free,
    input [8:0] n_reserved, n_issued,
    output adm_valid,
    output [7:0] adm_tag, adm_host_tag,
    output [12:0] adm_bc,
    output [6:0] adm_la,
    output [2:0] adm_tc,
    output [1:0] adm_attr,
    output [15:0] admitted_count,
    output [111:0] refuse_counts
);
    pcileech_req_gate #(.N_NP_MAX(N_NP_MAX)) i_gate (
        .clk(clk), .rst(rst), .live_rid(live_rid), .bme(bme),
        .mrrs_code(mrrs_code), .ext_tag_en(ext_tag_en),
        .free(free), .n_reserved(n_reserved), .n_issued(n_issued),
        .in_data(tlps_in.tdata), .in_keep(tlps_in.tkeepdw), .in_user(tlps_in.tuser),
        .in_last(tlps_in.tlast), .in_valid(tlps_in.tvalid), .in_ready(tlps_in.tready),
        .out_data(tlps_out.tdata), .out_keep(tlps_out.tkeepdw), .out_user(tlps_out.tuser),
        .out_last(tlps_out.tlast), .out_valid(tlps_out.tvalid), .out_ready(tlps_out.tready),
        .out_has_data(tlps_out.has_data),
        .adm_valid(adm_valid), .adm_tag(adm_tag), .adm_host_tag(adm_host_tag),
        .adm_bc(adm_bc), .adm_la(adm_la), .adm_tc(adm_tc), .adm_attr(adm_attr),
        .admitted_count(admitted_count), .refuse_counts(refuse_counts));

    // Pulls may be speculative: the upstream mux returns no valid beat when
    // none of its sources has_data. No dependence on has_data is needed here.
    wire _unused = &{1'b0, tlps_in.has_data};
endmodule
