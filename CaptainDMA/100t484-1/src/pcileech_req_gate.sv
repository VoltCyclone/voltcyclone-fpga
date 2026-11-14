// R1 requester tracking: pull-stream admission gate.
`timescale 1ns / 1ps
`include "pcileech_req_defs.svh"
module pcileech_req_gate (
    input clk, rst,
    // In-flight non-posted cap from pcileech_req_np_cap (live advertised NP
    // credit, contract section 8). 0 = not yet sampled: every NP request is
    // refused with REFUSE_NP_CAP.
    input [8:0] np_cap,
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
    // Input register: a pulled beat lands here one cycle after it arrives, so
    // classification and admission start from flops rather than from the
    // upstream FIFO's block-RAM output and the merge mux (timing F1).
    reg s_valid;
    reg [127:0] s_data;
    reg [3:0] s_keep;
    reg [8:0] s_user;
    reg s_last;
    reg pulled;            // in_ready last cycle: a response may arrive now (both clear in rst)
    always @(posedge clk) begin
        s_valid <= !rst && in_valid;
        pulled <= in_ready;
        if (in_valid) begin
            s_data <= in_data; s_keep <= in_keep; s_user <= in_user; s_last <= in_last;
        end
    end

    // Classify at register arrival: downstream stalls must not change a decision
    // or cause a second admission. The merged arbiter keeps packets contiguous.
    reg in_packet, drop_packet;
    wire start_packet = !in_packet;
    wire [1:0] cls;
    wire [3:0] reason;
    wire tag_avail;
    pcileech_req_classify i_classify (
        .hdr(s_data), .first(s_user[0]), .last(s_last),
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
        if (!s_user[0])
            refuse_reason = `REQ_REFUSE_MALFORMED; // orphan tail after reset
        else if (cls == `REQ_CLS_REFUSE)
            refuse_reason = reason;
        else if (cls == `REQ_CLS_TRACK) begin
            if (!tag_avail) refuse_reason = `REQ_REFUSE_NO_TAG;
            else if ((n_np < {1'b0, np_cap}) !== 1'b1) refuse_reason = `REQ_REFUSE_NP_CAP;
        end
    end
    wire refuse = start_packet && (refuse_reason != `REQ_REFUSE_NONE);
    wire drop_beat = start_packet ? refuse : drop_packet;
    assign adm_valid = !rst && s_valid && start_packet &&
                       (cls == `REQ_CLS_TRACK) && !refuse;

    // A pull in cycle n promises space for a response in n+1, regardless of
    // n+1's downstream ready; the response reaches the queue from the input
    // register in n+2. Three queue entries cover the registered beat and the
    // pull in flight on a sudden downstream stall: pull only while the queue
    // after this cycle, plus a possible response to last cycle's pull, leaves
    // room for one more. The output is itself a registered pull response; its
    // valid is NOT gated by current out_ready.
    reg [127:0] q_data[0:2];
    reg [3:0] q_keep[0:2];
    reg [8:0] q_user[0:2];
    reg q_last[0:2];
    reg [1:0] q_count;
    reg [1:0] q_head;
    wire push = !rst && s_valid && !drop_beat;
    wire pop = !rst && out_ready && (q_count != 0);
    wire [1:0] q_count_next = q_count + {1'b0,push} - {1'b0,pop};
    wire [2:0] q_wsum = {1'b0,q_head} + {1'b0,q_count};
    wire [1:0] q_tail = q_wsum >= 3'd3 ? q_wsum[1:0] - 2'd3 : q_wsum[1:0];
    assign in_ready = !rst && ({1'b0,q_count_next} + {2'b0,pulled} <= 3'd2);
    assign out_has_data = !rst && (q_count != 0);

    reg [127:0] rewritten;
    always @* begin
        rewritten = s_data;
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
                q_data[q_tail] <= rewritten;
                q_keep[q_tail] <= s_keep;
                q_user[q_tail] <= s_user;
                q_last[q_tail] <= s_last;
            end
            out_valid <= pop;
            if (pop) begin
                out_data <= q_data[q_head]; out_keep <= q_keep[q_head];
                out_user <= q_user[q_head]; out_last <= q_last[q_head];
                q_head <= q_head == 2'd2 ? 2'd0 : q_head + 2'd1;
            end
            if (s_valid) begin
                in_packet <= !s_last;
                if (s_last) drop_packet <= 0;
                else if (start_packet) drop_packet <= refuse;
                if (refuse && refuse_count[refuse_reason[2:0]] != 16'hffff)
                    refuse_count[refuse_reason[2:0]] <= refuse_count[refuse_reason[2:0]] + 16'd1;
            end
            if (adm_valid && admitted_count != 16'hffff)
                admitted_count <= admitted_count + 16'd1;
        end
    end
endmodule
