//
// PCILeech FPGA.
//
// R1 requester tracking: combinational first-beat classifier.
// Contract: PCILeechFWGenerator docs/development/MSIX_REQUESTER_CONTRACT.md sections 3-4.
//
// Decodes one TX beat and decides whether the packet passes untracked, is a memory
// read to track, or is refused. For tracked reads it also produces the request's
// total Byte Count and the Lower Address of its first completion (PCIe Base 3.0
// section 2.3.1.1, Tables 2-32 and 2-33). Tag and NP-cap admission (checks 7-8)
// need table state and are decided by the gate, not here.
//
`timescale 1ns / 1ps
`include "pcileech_req_defs.svh"

module pcileech_req_classify (
    input  [127:0]  hdr,            // first beat: DW0 = [31:0] ... DW3 = [127:96]
    input           first,
    input           last,
    input  [15:0]   live_rid,       // this function's ID in wire order {bus, dev, fn}
    input           bme,            // cfg_command[2]
    input  [2:0]    mrrs_code,      // cfg_dcommand[14:12]
    output [1:0]    cls,
    output [3:0]    reason,
    output [7:0]    host_tag,
    output [2:0]    tc,
    output [1:0]    attr,
    output [12:0]   byte_count,     // initial 'remaining', 1..4096
    output [6:0]    lower_addr      // expected Lower Address of the first completion
);
    // ---- header fields --------------------------------------------------------------
    wire [2:0]  fmt     = hdr[31:29];
    wire [4:0]  typ     = hdr[28:24];
    wire        td      = hdr[15];
    wire [9:0]  len     = hdr[9:0];
    wire [15:0] rid     = hdr[63:48];
    wire [3:0]  lbe     = hdr[39:36];
    wire [3:0]  fbe     = hdr[35:32];
    wire        is64    = fmt[0];
    wire [31:0] addr_hi = hdr[95:64];                       // MRd64 only
    wire [31:0] addr_lo = is64 ? hdr[127:96] : hdr[95:64];  // address [31:2]

    assign host_tag = hdr[47:40];
    assign tc       = hdr[22:20];
    assign attr     = hdr[13:12];

    // ---- class (contract section 3 table) -----------------------------------------
    wire is_mrd  = (typ == 5'b00000) && (fmt == 3'b000 || fmt == 3'b001);
    wire is_mwr  = (typ == 5'b00000) && (fmt == 3'b010 || fmt == 3'b011);
    wire is_msg  = (typ[4:3] == 2'b10) && (fmt == 3'b001 || fmt == 3'b011);
    wire is_cpl  = (typ == 5'b01010 || typ == 5'b01011) && (fmt == 3'b000 || fmt == 3'b010);

    // ---- byte-enable helpers ----------------------------------------------------------
    function automatic [1:0] lsb4(input [3:0] be);   // lowest enabled byte (0 if none)
        lsb4 = be[0] ? 2'd0 : be[1] ? 2'd1 : be[2] ? 2'd2 : be[3] ? 2'd3 : 2'd0;
    endfunction
    // highest enabled byte (0 if none); be[0] alone also yields 0, so it is not read
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [1:0] msb4(input [3:0] be);
        msb4 = be[3] ? 2'd3 : be[2] ? 2'd2 : be[1] ? 2'd1 : 2'd0;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- check 5: length, MRRS, 4 KB, byte enables ------------------------------------
    wire [10:0] len_dw    = (len == 10'd0) ? 11'd1024 : {1'b0, len};
    wire [12:0] len_bytes = {len_dw, 2'b00};
    wire [12:0] mrrs_bytes = (mrrs_code > 3'd5) ? 13'd128 : (13'd128 << mrrs_code);
    wire [11:0] end_dw    = {2'b00, addr_lo[11:2]} + {1'b0, len_dw};
    wire        cross_4k  = end_dw > 12'd1024;
    wire        len_one   = (len_dw == 11'd1);
    wire        qw_pair   = (len_dw == 11'd2) && !addr_lo[2];
    wire        fbe_contig = (fbe == 4'b1111) || (fbe == 4'b1110) || (fbe == 4'b1100) || (fbe == 4'b1000);
    wire        lbe_contig = (lbe == 4'b1111) || (lbe == 4'b0111) || (lbe == 4'b0011) || (lbe == 4'b0001);
    wire        be_bad    = len_one ? (lbe != 4'b0000)
                          : (fbe == 4'b0000) || (lbe == 4'b0000) ||
                            (!qw_pair && !(fbe_contig && lbe_contig));
    wire        bad_len   = (len_bytes > mrrs_bytes) || cross_4k || be_bad;
    wire        bad_64    = is64 && (addr_hi == 32'h0);              // check 6
    wire        bad_shape = !(first && last);                         // check 1

    // ---- disposition, checks in contract order ----------------------------------------
    reg [1:0] r_cls;
    reg [3:0] r_reason;
    always @* begin
        r_cls    = `REQ_CLS_REFUSE;
        r_reason = `REQ_REFUSE_CLASS;
        if (is_mwr || is_msg || is_cpl) begin
            r_cls = `REQ_CLS_PASS;  r_reason = `REQ_REFUSE_NONE;
        end else if (is_mrd) begin
            if      (bad_shape)            r_reason = `REQ_REFUSE_MALFORMED;
            else if (td)                   r_reason = `REQ_REFUSE_TD;
            else if (rid != live_rid)      r_reason = `REQ_REFUSE_RID;
            else if (!bme)                 r_reason = `REQ_REFUSE_BME;
            else if (bad_len || bad_64)    r_reason = `REQ_REFUSE_MALFORMED;
            else begin
                r_cls = `REQ_CLS_TRACK;  r_reason = `REQ_REFUSE_NONE;
            end
        end
    end
    assign cls    = r_cls;
    assign reason = r_reason;

    // ---- Byte Count and Lower Address (Tables 2-32 / 2-33) ----------------------------
    wire [12:0] bc_one   = (fbe == 4'b0000) ? 13'd1
                         : {11'd0, msb4(fbe)} - {11'd0, lsb4(fbe)} + 13'd1;
    wire [12:0] bc_multi = len_bytes - {11'd0, lsb4(fbe)} - {11'd0, 2'd3 - msb4(lbe)};
    assign byte_count = len_one ? bc_one : bc_multi;
    assign lower_addr = {addr_lo[6:2], lsb4(fbe)};

    // Header bits this block does not interpret.
    wire _unused = &{1'b0, hdr[23], hdr[19:16], hdr[14], hdr[11:10], addr_lo[31:12],
                     addr_lo[1:0], 1'b0};
endmodule
