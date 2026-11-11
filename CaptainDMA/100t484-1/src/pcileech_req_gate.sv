// R1 requester tracking: pull-stream admission gate.
`timescale 1ns / 1ps
`include "pcileech_req_defs.svh"
module pcileech_req_gate #(parameter integer N_NP_MAX = 0) (
    input clk, rst,
    input [15:0] live_rid,
    input bme,
    input [2:0] mrrs_code,
    input ext_tag_en,
    input [255:0] free,
    input [8:0] n_reserved, n_issued,
    input [127:0] in_data,
    input [3:0] in_keep,
    input [8:0] in_user,
    input in_last, in_valid,
    output in_ready,
    output reg [127:0] out_data,
    output reg [3:0] out_keep,
    output reg [8:0] out_user,
    output reg out_last, out_valid,
    input out_ready,
    output out_has_data,
    output adm_valid,
    output [7:0] adm_tag, adm_host_tag,
    output [12:0] adm_bc,
    output [6:0] adm_la,
    output [2:0] adm_tc,
    output [1:0] adm_attr,
    output reg [15:0] admitted_count,
    output [111:0] refuse_counts
);
    // Bind this from the generated tracking plan, using the advertised NP
    // credit bound (contract sections 3/8). Zero intentionally fails closed.
    initial begin
        if (N_NP_MAX < 1 || N_NP_MAX > 256)
            $fatal(1, "req_gate requires N_NP_MAX in 1..256 from the tracking plan");
    end

    // Classify at input arrival: downstream stalls must not change a decision
    // or cause a second admission. The merged arbiter keeps packets contiguous.
    reg in_packet, drop_packet;
    wire start_packet = !in_packet;
    wire [1:0] cls;
    wire [3:0] reason;
    wire tag_avail;
    pcileech_req_classify i_classify (
        .hdr(in_data), .first(in_user[0]), .last(in_last),
        .live_rid(live_rid), .bme(bme), .mrrs_code(mrrs_code),
        .cls(cls), .reason(reason), .host_tag(adm_host_tag), .tc(adm_tc),
        .attr(adm_attr), .byte_count(adm_bc), .lower_addr(adm_la));
    pcileech_req_tagalloc i_tagalloc (
        .clk(clk), .rst(rst), .free(free), .ext_tag_en(ext_tag_en),
        .take(adm_valid), .avail(tag_avail), .tag(adm_tag));

    wire [9:0] n_np = {1'b0,n_reserved} + {1'b0,n_issued};
    reg [3:0] refuse_reason;
    always @* begin
        refuse_reason = `REQ_REFUSE_NONE;
        if (!in_user[0])
            refuse_reason = `REQ_REFUSE_MALFORMED; // orphan tail after reset
        else if (cls == `REQ_CLS_REFUSE)
            refuse_reason = reason;
        else if (cls == `REQ_CLS_TRACK) begin
            if (!tag_avail) refuse_reason = `REQ_REFUSE_NO_TAG;
            else if (n_np >= 10'(N_NP_MAX)) refuse_reason = `REQ_REFUSE_NP_CAP;
        end
    end
    wire refuse = start_packet && (refuse_reason != `REQ_REFUSE_NONE);
    wire drop_beat = start_packet ? refuse : drop_packet;
    assign adm_valid = !rst && in_valid && start_packet &&
                       (cls == `REQ_CLS_TRACK) && !refuse;

    // A pull in cycle n promises space for a response in n+1, regardless of
    // n+1's downstream ready. Two queue entries cover that in-flight response
    // on a sudden downstream stall. The output is itself a registered pull
    // response; its valid is NOT gated by current out_ready.
    reg [127:0] q_data[0:1];
    reg [3:0] q_keep[0:1];
    reg [8:0] q_user[0:1];
    reg q_last[0:1];
    reg [1:0] q_count;
    reg q_head;
    wire push = !rst && in_valid && !drop_beat;
    wire pop = !rst && out_ready && (q_count != 0);
    wire [1:0] q_count_next = q_count + {1'b0,push} - {1'b0,pop};
    assign in_ready = !rst && (q_count_next <= 2'd1);
    assign out_has_data = !rst && (q_count != 0);

    reg [127:0] rewritten;
    always @* begin
        rewritten = in_data;
        if (adm_valid) rewritten[47:40] = adm_tag;
    end
    reg [15:0] refuse_count[1:7];
    genvar g;
    generate for (g=1; g<=7; g=g+1) begin : g_counts
        assign refuse_counts[(g-1)*16 +: 16] = refuse_count[g];
    end endgenerate
    integer k;
    always @(posedge clk) begin
        if (rst) begin
            q_count <= 0; q_head <= 0;
            in_packet <= 0; drop_packet <= 0;
            out_data <= 0; out_keep <= 0; out_user <= 0;
            out_last <= 0; out_valid <= 0; admitted_count <= 0;
            for (k=1; k<=7; k=k+1) refuse_count[k] <= 0;
        end else begin
            q_count <= q_count_next;
            if (push) begin
                q_data[q_head ^ q_count[0]] <= rewritten;
                q_keep[q_head ^ q_count[0]] <= in_keep;
                q_user[q_head ^ q_count[0]] <= in_user;
                q_last[q_head ^ q_count[0]] <= in_last;
            end
            out_valid <= pop;
            if (pop) begin
                out_data <= q_data[q_head]; out_keep <= q_keep[q_head];
                out_user <= q_user[q_head]; out_last <= q_last[q_head];
                q_head <= ~q_head;
            end
            if (in_valid) begin
                in_packet <= !in_last;
                if (in_last) drop_packet <= 0;
                else if (start_packet) drop_packet <= refuse;
                if (refuse && refuse_count[refuse_reason[2:0]] != 16'hffff)
                    refuse_count[refuse_reason[2:0]] <= refuse_count[refuse_reason[2:0]] + 16'd1;
            end
            if (adm_valid && admitted_count != 16'hffff)
                admitted_count <= admitted_count + 16'd1;
        end
    end
endmodule
