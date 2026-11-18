//
// PCILeech FPGA.
//
// R1 requester tracking: shared encodings.
// Contract: PCILeechFWGenerator docs/development/MSIX_REQUESTER_CONTRACT.md.
//
`ifndef PCILEECH_REQ_DEFS_SVH
`define PCILEECH_REQ_DEFS_SVH

// Classification of a TX packet's first beat (contract section 3).
`define REQ_CLS_PASS            2'd0    // posted or completer response: pass unmodified, untracked
`define REQ_CLS_TRACK           2'd1    // MRd32/MRd64 admitted for tracking
`define REQ_CLS_REFUSE          2'd2    // discarded through tlast, counted

// Refusal reasons (contract section 3, checks 1-8).
`define REQ_REFUSE_NONE         4'd0
`define REQ_REFUSE_CLASS        4'd1
`define REQ_REFUSE_MALFORMED    4'd2
`define REQ_REFUSE_TD           4'd3
`define REQ_REFUSE_RID          4'd4
`define REQ_REFUSE_BME          4'd5
`define REQ_REFUSE_NO_TAG       4'd6
`define REQ_REFUSE_NP_CAP       4'd7

// Entry states (contract section 6).
`define REQ_ST_FREE             2'd0
`define REQ_ST_RESERVED         2'd1
`define REQ_ST_ISSUED           2'd2
`define REQ_ST_QUARANTINED      2'd3

`endif
