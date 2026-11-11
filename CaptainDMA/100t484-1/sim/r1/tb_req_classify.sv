// Self-checking bench for pcileech_req_classify.
// Expectations come from MSIX_REQUESTER_CONTRACT.md sections 3-4 and PCIe Base 3.0
// (B3) section 2.2.5 / 2.3.1.1 Tables 2-32 and 2-33. Prints R1_TB_PASS on success.
`timescale 1ns / 1ps
`include "pcileech_req_defs.svh"

module tb_req_classify;
    reg  [127:0] hdr;
    reg          first, last, bme;
    reg  [15:0]  live_rid;
    reg  [2:0]   mrrs_code;
    wire [1:0]   cls;
    wire [3:0]   reason;
    wire [7:0]   host_tag;
    wire [2:0]   tc;
    wire [1:0]   attr;
    wire [12:0]  byte_count;
    wire [6:0]   lower_addr;

    pcileech_req_classify dut (
        .hdr(hdr), .first(first), .last(last), .live_rid(live_rid), .bme(bme),
        .mrrs_code(mrrs_code), .cls(cls), .reason(reason), .host_tag(host_tag),
        .tc(tc), .attr(attr), .byte_count(byte_count), .lower_addr(lower_addr));

    localparam [15:0] RID = 16'h0310;   // bus 3, dev 2, fn 0 in wire order
    integer errors = 0, checks = 0;

    // Generic header: DW0 fields per B3 Fig 2-4.
    function [31:0] dw0;
        input [2:0] fmt; input [4:0] typ; input [2:0] t_c; input td; input [1:0] at;
        input [9:0] len;
        dw0 = {fmt, typ, 1'b0, t_c, 1'b0, 1'b0, 1'b0, 1'b0, td, 1'b0, at, 2'b00, len};
    endfunction

    function [127:0] mrd;
        input        is64; input [15:0] rid; input [7:0] tag; input [3:0] lbe;
        input [3:0]  fbe;  input [9:0] len;  input [63:0] addr; input td;
        input [2:0]  t_c;  input [1:0] at;
        reg [31:0] d0, d1, d2, d3;
        begin
            d0 = dw0(is64 ? 3'b001 : 3'b000, 5'b00000, t_c, td, at, len);
            d1 = {rid, tag, lbe, fbe};
            if (is64) begin d2 = addr[63:32]; d3 = {addr[31:2], 2'b00}; end
            else      begin d2 = {addr[31:2], 2'b00}; d3 = 32'h0; end
            mrd = {d3, d2, d1, d0};
        end
    endfunction

    // A simple tracked read: MRd32, 1 DW, FBE 1111, at 0x1000.
    function [127:0] mrd32_ok;
        input [7:0] tag;
        mrd32_ok = mrd(0, RID, tag, 4'h0, 4'hF, 10'd1, 64'h1000, 0, 3'd0, 2'b00);
    endfunction

    function [127:0] other;  // any non-MRd header: only Fmt/Type matter
        input [2:0] fmt; input [4:0] typ;
        other = {96'h0, dw0(fmt, typ, 3'd0, 1'b0, 2'b00, 10'd1)};
    endfunction

    task apply;
        input [127:0] h; input f; input l;
        begin
            hdr = h; first = f; last = l; #1;
        end
    endtask

    task expect_cls;
        input [8*40-1:0] name; input [1:0] want_cls; input [3:0] want_reason;
        begin
            checks = checks + 1;
            if (cls !== want_cls || reason !== want_reason) begin
                errors = errors + 1;
                $display("R1_TB_FAIL %0s: cls=%0d reason=%0d want cls=%0d reason=%0d",
                         name, cls, reason, want_cls, want_reason);
            end
        end
    endtask

    task expect_track;
        input [8*40-1:0] name; input [12:0] want_bc; input [6:0] want_la;
        begin
            expect_cls(name, `REQ_CLS_TRACK, `REQ_REFUSE_NONE);
            checks = checks + 1;
            if (byte_count !== want_bc || lower_addr !== want_la) begin
                errors = errors + 1;
                $display("R1_TB_FAIL %0s: byte_count=%0d lower_addr=%h want %0d/%h",
                         name, byte_count, lower_addr, want_bc, want_la);
            end
        end
    endtask

    initial begin
        live_rid = RID; bme = 1'b1; mrrs_code = 3'd2;  // 512-byte MRRS

        // ---- classes (contract section 3 table) -----------------------------------
        apply(mrd32_ok(8'h01), 1, 1);  expect_track("mrd32 tracked", 13'd4, 7'h00);
        apply(mrd(1, RID, 8'h02, 4'h0, 4'hF, 10'd1, 64'h1_0000_2040, 0, 3'd0, 2'b00), 1, 1);
        expect_track("mrd64 tracked", 13'd4, 7'h40);
        apply(other(3'b010, 5'b00000), 1, 0); expect_cls("mwr32 pass, multi-beat", `REQ_CLS_PASS, `REQ_REFUSE_NONE);
        apply(other(3'b011, 5'b00000), 1, 1); expect_cls("mwr64 pass", `REQ_CLS_PASS, `REQ_REFUSE_NONE);
        apply(other(3'b001, 5'b10000), 1, 1); expect_cls("msg pass", `REQ_CLS_PASS, `REQ_REFUSE_NONE);
        apply(other(3'b011, 5'b10100), 1, 0); expect_cls("msgd pass", `REQ_CLS_PASS, `REQ_REFUSE_NONE);
        apply(other(3'b000, 5'b01010), 1, 1); expect_cls("cpl pass", `REQ_CLS_PASS, `REQ_REFUSE_NONE);
        apply(other(3'b010, 5'b01010), 1, 0); expect_cls("cpld pass", `REQ_CLS_PASS, `REQ_REFUSE_NONE);
        apply(other(3'b000, 5'b01011), 1, 1); expect_cls("cpllk pass", `REQ_CLS_PASS, `REQ_REFUSE_NONE);
        apply(other(3'b010, 5'b01011), 1, 0); expect_cls("cpldlk pass", `REQ_CLS_PASS, `REQ_REFUSE_NONE);
        apply(other(3'b000, 5'b00001), 1, 1); expect_cls("mrdlk refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);
        apply(other(3'b000, 5'b00010), 1, 1); expect_cls("iord refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);
        apply(other(3'b010, 5'b00010), 1, 0); expect_cls("iowr refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);
        apply(other(3'b000, 5'b00100), 1, 1); expect_cls("cfgrd0 refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);
        apply(other(3'b010, 5'b00101), 1, 0); expect_cls("cfgwr1 refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);
        apply(other(3'b010, 5'b01100), 1, 0); expect_cls("fetchadd refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);
        apply(other(3'b011, 5'b01101), 1, 0); expect_cls("swap refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);
        apply(other(3'b010, 5'b01110), 1, 0); expect_cls("cas refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);
        apply(other(3'b100, 5'b00000), 1, 0); expect_cls("tlp prefix refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);
        apply(other(3'b000, 5'b11111), 1, 1); expect_cls("undefined type refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);
        apply(other(3'b001, 5'b01010), 1, 1); expect_cls("cpl with 4dw fmt refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);
        apply(other(3'b000, 5'b10000), 1, 1); expect_cls("msg with 3dw fmt refused", `REQ_CLS_REFUSE, `REQ_REFUSE_CLASS);

        // ---- tracked-read checks 1-6 ----------------------------------------------------
        apply(mrd32_ok(8'h03), 1, 0); expect_cls("check1 mrd not single beat", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);
        apply(mrd32_ok(8'h03), 0, 1); expect_cls("check1 mrd not a first beat", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);
        apply(mrd(0, RID, 8'h04, 4'h0, 4'hF, 10'd1, 64'h1000, 1, 3'd0, 2'b00), 1, 1);
        expect_cls("check2 td set", `REQ_CLS_REFUSE, `REQ_REFUSE_TD);
        apply(mrd(0, 16'h0311, 8'h05, 4'h0, 4'hF, 10'd1, 64'h1000, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("check3 foreign rid", `REQ_CLS_REFUSE, `REQ_REFUSE_RID);
        bme = 1'b0; apply(mrd32_ok(8'h06), 1, 1);
        expect_cls("check4 bme clear", `REQ_CLS_REFUSE, `REQ_REFUSE_BME);
        bme = 1'b1;
        // precedence follows the contract's listed order: TD (2) before RID (3)
        apply(mrd(0, 16'h0311, 8'h07, 4'h0, 4'hF, 10'd1, 64'h1000, 1, 3'd0, 2'b00), 1, 1);
        expect_cls("precedence td before rid", `REQ_CLS_REFUSE, `REQ_REFUSE_TD);

        // check 5: byte-enable rules
        apply(mrd(0, RID, 8'h10, 4'h1, 4'hF, 10'd1, 64'h1000, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("len1 with last_be set", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);
        apply(mrd(0, RID, 8'h11, 4'hF, 4'h0, 10'd2, 64'h1000, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("len2 first_be zero", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);
        apply(mrd(0, RID, 8'h12, 4'h0, 4'hF, 10'd2, 64'h1000, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("len2 last_be zero", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);
        apply(mrd(0, RID, 8'h13, 4'hF, 4'h6, 10'd4, 64'h1000, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("len4 first_be not contiguous to top", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);
        apply(mrd(0, RID, 8'h14, 4'hC, 4'hF, 10'd4, 64'h1000, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("len4 last_be not contiguous from bit0", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);
        apply(mrd(0, RID, 8'h15, 4'hA, 4'h5, 10'd2, 64'h1000, 0, 3'd0, 2'b00), 1, 1);
        expect_track("len2 qw-aligned non-contiguous ok", 13'd8, 7'h00);
        apply(mrd(0, RID, 8'h16, 4'hA, 4'h5, 10'd2, 64'h1004, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("len2 not qw-aligned non-contiguous", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);

        // Byte Count / Lower Address (contract section 4, B3 Tables 2-32/2-33)
        apply(mrd(0, RID, 8'h20, 4'h0, 4'h9, 10'd1, 64'h1000, 0, 3'd0, 2'b00), 1, 1);
        expect_track("len1 be 1001 span is 4", 13'd4, 7'h00);
        apply(mrd(0, RID, 8'h21, 4'h0, 4'h0, 10'd1, 64'h1044, 0, 3'd0, 2'b00), 1, 1);
        expect_track("len1 be 0000 zero-length read", 13'd1, 7'h44);
        apply(mrd(0, RID, 8'h22, 4'h0, 4'h4, 10'd1, 64'h1008, 0, 3'd0, 2'b00), 1, 1);
        expect_track("len1 be 0100 one byte at offset 2", 13'd1, 7'h0A);
        apply(mrd(0, RID, 8'h23, 4'h7, 4'hC, 10'd4, 64'h1010, 0, 3'd0, 2'b00), 1, 1);
        expect_track("len4 be c/7 is 13 bytes", 13'd13, 7'h12);
        apply(mrd(0, RID, 8'h24, 4'hF, 4'hF, 10'd32, 64'h1F7C, 0, 3'd0, 2'b00), 1, 1);
        expect_track("lower addr uses addr[6:2]", 13'd128, 7'h7C);

        // MRRS and 4 KB boundary
        mrrs_code = 3'd0;  // 128 bytes
        apply(mrd(0, RID, 8'h30, 4'hF, 4'hF, 10'd32, 64'h2000, 0, 3'd0, 2'b00), 1, 1);
        expect_track("mrrs 128 len32 ok", 13'd128, 7'h00);
        apply(mrd(0, RID, 8'h31, 4'hF, 4'hF, 10'd33, 64'h2000, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("mrrs 128 len33 refused", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);
        mrrs_code = 3'd6;  // reserved encoding: treated as the smallest (128 B)
        apply(mrd(0, RID, 8'h32, 4'hF, 4'hF, 10'd33, 64'h2000, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("mrrs reserved acts as 128", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);
        mrrs_code = 3'd5;  // 4096 bytes
        apply(mrd(0, RID, 8'h33, 4'hF, 4'hF, 10'd0, 64'h3000, 0, 3'd0, 2'b00), 1, 1);
        expect_track("len0 is 1024 dw, 4096 bytes", 13'd4096, 7'h00);
        apply(mrd(0, RID, 8'h34, 4'hF, 4'hF, 10'd4, 64'h0FF8, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("crosses 4kb", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);
        apply(mrd(0, RID, 8'h35, 4'hF, 4'hF, 10'd4, 64'h0FF0, 0, 3'd0, 2'b00), 1, 1);
        expect_track("ends exactly at 4kb", 13'd16, 7'h70);
        apply(mrd(0, RID, 8'h36, 4'hF, 4'hF, 10'd2, 64'h1_0000_0FFC, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("mrd64 crosses 4kb", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);
        mrrs_code = 3'd2;

        // check 6: MRd64 must not carry a 32-bit address
        apply(mrd(1, RID, 8'h40, 4'h0, 4'hF, 10'd1, 64'h0000_0000_8000_0000, 0, 3'd0, 2'b00), 1, 1);
        expect_cls("mrd64 with zero upper address", `REQ_CLS_REFUSE, `REQ_REFUSE_MALFORMED);

        // ---- metadata echoed for the table ------------------------------------------------
        apply(mrd(0, RID, 8'hA5, 4'h0, 4'hF, 10'd1, 64'h1000, 0, 3'd3, 2'b10), 1, 1);
        checks = checks + 1;
        if (host_tag !== 8'hA5 || tc !== 3'd3 || attr !== 2'b10) begin
            errors = errors + 1;
            $display("R1_TB_FAIL metadata: tag=%h tc=%0d attr=%b", host_tag, tc, attr);
        end

        if (errors == 0) $display("R1_TB_PASS tb_req_classify checks=%0d", checks);
        else             $display("R1_TB_FAILED tb_req_classify errors=%0d checks=%0d", errors, checks);
        $finish;
    end
endmodule
