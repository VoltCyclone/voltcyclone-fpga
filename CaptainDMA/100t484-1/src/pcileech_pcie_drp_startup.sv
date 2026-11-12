// R1 reset-held DRP startup controller (contract section 11), clk_sys.
//
// While the PCIe core is held in reset (sys_rst_n low), read one DRP word,
// check that the generator-owned field bits (PLAN_CHECK_MASK) match the plan,
// write the planned bits, read back and require the whole written word.
// drp_ok gates rst_pcie_n; it clears on every reset-source assertion, so the
// sequence re-runs in every core reset episode. A failure keeps drp_ok low
// until the next reset-source assertion and records why.
//
// The DRP port is shared with the host bridge in pcileech_fifo. The bridge
// issues a one-cycle drp_en and then waits for drp_rdy. A host request that
// arrives while startup owns the port is latched and issued afterwards. The
// port switches owner only between transactions. Host writes to PLAN_ADDR are
// refused (answered with rdy and no core write) so they cannot undo the plan;
// host reads of PLAN_ADDR are allowed.
//
// Every transaction is bounded, host ones included: if drp_rdy does not come
// within RDY_TIMEOUT_CYCLES, a host request is answered with 16'hFFFF and
// counted, a startup request fails the attempt. Either way the port then
// drains for another RDY_TIMEOUT_CYCLES so a late rdy is absorbed rather than
// taken as the answer to the next request. (A rdy later than that remains
// unattributable; a DRP that slow means the core is unusable.)
//
// Plan parameters come from the generated RequesterTrackingPlan. PLAN_BOUND
// must be 1: there are deliberately no usable defaults.
`timescale 1ns / 1ps
module pcileech_pcie_drp_startup #(
    parameter integer   PLAN_BOUND          = 0,
    parameter [8:0]     PLAN_ADDR           = 9'h019,
    parameter [15:0]    PLAN_MASK           = 16'h0000,
    parameter [15:0]    PLAN_VALUE          = 16'h0000,
    parameter [15:0]    PLAN_CHECK_MASK     = 16'h0000,  // bits compared before writing
    parameter [15:0]    PLAN_BASE_EXPECT    = 16'h0000,  // expected value of those bits
    parameter integer   RDY_TIMEOUT_CYCLES  = 0
) (
    input               clk,
    input               rst_src,            // rst || ~perst_n || pcie_rst_core (clk_sys)
    output reg          drp_ok,             // gate for rst_pcie_n
    // host bridge side
    input               host_en,
    input               host_we,
    input        [8:0]  host_addr,
    input       [15:0]  host_di,
    output reg          host_rdy,
    output reg  [15:0]  host_do,
    // core DRP port
    output reg          drp_en,
    output reg          drp_we,
    output reg   [8:0]  drp_addr,
    output reg  [15:0]  drp_di,
    input               drp_rdy,
    input       [15:0]  drp_do,
    // status
    output reg          failed,             // last attempt failed; core held in reset
    output reg   [1:0]  fail_reason,        // 1 rdy timeout, 2 base mismatch, 3 verify mismatch
    output reg   [7:0]  fail_count,         // saturating, attempts that failed
    output reg  [15:0]  read_word,          // word read at the start of the last attempt
    output reg  [15:0]  verify_word,        // word read back by the last attempt
    output reg   [7:0]  host_refused_count, // saturating, host writes to PLAN_ADDR refused
    output reg   [7:0]  host_timeout_count, // saturating, host transactions without drp_rdy
    output reg          fail_sticky         // any attempt failed since configuration
);
    initial begin
        if (PLAN_BOUND != 1)
            $fatal(1, "drp_startup requires PLAN_BOUND=1 and plan values from the tracking plan");
        if (RDY_TIMEOUT_CYCLES < 16 || RDY_TIMEOUT_CYCLES > 65535)
            $fatal(1, "drp_startup RDY_TIMEOUT_CYCLES must be 16..65535");
        if ((PLAN_VALUE & ~PLAN_MASK) != 16'h0000)
            $fatal(1, "drp_startup PLAN_VALUE has bits outside PLAN_MASK");
        if (PLAN_CHECK_MASK == 16'h0000 || (PLAN_CHECK_MASK & PLAN_MASK) != 16'h0000)
            $fatal(1, "drp_startup PLAN_CHECK_MASK must be nonzero and outside PLAN_MASK");
        if ((PLAN_BASE_EXPECT & ~PLAN_CHECK_MASK) != 16'h0000)
            $fatal(1, "drp_startup PLAN_BASE_EXPECT has bits outside PLAN_CHECK_MASK");
    end
    localparam [1:0] R_NONE = 2'd0, R_TIMEOUT = 2'd1, R_BASE = 2'd2, R_VERIFY = 2'd3;

    // ---- startup sequence ---------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0, S_READ = 3'd1, S_WRITE = 3'd2, S_VERIFY = 3'd3,
                     S_HOST = 3'd4, S_DRAIN = 3'd5;
    reg  [2:0]  state;
    reg         need_run;           // a reset source asserted since the last attempt began
    reg         abort;              // reset source asserted during an attempt
    reg  [15:0] wait_cycles;
    reg  [15:0] write_word;
    // host request latch
    reg         hp_valid, hp_we;
    reg  [8:0]  hp_addr;
    reg  [15:0] hp_di;
    initial begin
        state = S_IDLE; need_run = 1'b1; abort = 1'b0; drp_ok = 1'b0;
        failed = 1'b0; fail_reason = R_NONE; fail_count = 8'd0;
        read_word = 16'd0; verify_word = 16'd0; write_word = 16'd0;
        host_refused_count = 8'd0; host_timeout_count = 8'd0; fail_sticky = 1'b0;
        wait_cycles = 16'd0;
        hp_valid = 1'b0; hp_we = 1'b0; hp_addr = 9'd0; hp_di = 16'd0;
        drp_en = 1'b0; drp_we = 1'b0; drp_addr = 9'd0; drp_di = 16'd0;
        host_rdy = 1'b0; host_do = 16'd0;
    end

    wire waiting = state == S_READ || state == S_WRITE || state == S_VERIFY;
    wire window_end = !drp_rdy && wait_cycles == 16'(RDY_TIMEOUT_CYCLES - 1);
    wire timed_out = (waiting || state == S_HOST) && window_end;
    wire counting = waiting || state == S_HOST || state == S_DRAIN;
    wire refuse_host = hp_valid && hp_we && hp_addr == PLAN_ADDR;
    wire start = state == S_IDLE && need_run && !rst_src;
    wire [15:0] planned = (drp_do & ~PLAN_MASK) | PLAN_VALUE;

    task automatic issue(input we, input [8:0] addr, input [15:0] di);
        begin
            drp_en <= 1'b1; drp_we <= we; drp_addr <= addr; drp_di <= di;
        end
    endtask
    task automatic finish_fail(input [1:0] reason);
        begin
            failed <= 1'b1;
            fail_sticky <= 1'b1;
            fail_reason <= reason;
            if (fail_count != 8'hff) fail_count <= fail_count + 8'd1;
            state <= reason == R_TIMEOUT ? S_DRAIN : S_IDLE;
        end
    endtask

    always @(posedge clk) begin
        drp_en <= 1'b0;
        drp_we <= 1'b0;
        host_rdy <= 1'b0;
        if (host_en && !hp_valid) begin
            hp_valid <= 1'b1; hp_we <= host_we; hp_addr <= host_addr; hp_di <= host_di;
        end
        wait_cycles <= counting && !drp_rdy && !window_end ? wait_cycles + 16'd1 : 16'd0;

        if (rst_src) begin
            drp_ok <= 1'b0;
            need_run <= 1'b1;
            if (waiting) abort <= 1'b1;
        end

        case (state)
            S_IDLE:
                if (start) begin
                    need_run <= 1'b0;
                    abort <= 1'b0;
                    failed <= 1'b0;
                    fail_reason <= R_NONE;
                    issue(1'b0, PLAN_ADDR, 16'd0);
                    state <= S_READ;
                end else if (hp_valid && !refuse_host) begin
                    issue(hp_we, hp_addr, hp_di);
                    state <= S_HOST;
                end else if (refuse_host) begin
                    hp_valid <= 1'b0;
                    host_rdy <= 1'b1;
                    host_do <= 16'd0;
                    if (host_refused_count != 8'hff)
                        host_refused_count <= host_refused_count + 8'd1;
                end
            S_HOST:
                if (drp_rdy) begin
                    hp_valid <= 1'b0;
                    host_rdy <= 1'b1;
                    host_do <= drp_do;
                    state <= S_IDLE;
                end else if (timed_out) begin
                    hp_valid <= 1'b0;
                    host_rdy <= 1'b1;
                    host_do <= 16'hffff;
                    if (host_timeout_count != 8'hff)
                        host_timeout_count <= host_timeout_count + 8'd1;
                    state <= S_DRAIN;
                end
            S_DRAIN:                        // absorb a late rdy from a timed-out request
                if (drp_rdy || window_end) state <= S_IDLE;
            S_READ:
                if (drp_rdy) begin
                    read_word <= drp_do;
                    if (abort || rst_src) state <= S_IDLE;
                    else if ((drp_do & PLAN_CHECK_MASK) != PLAN_BASE_EXPECT) finish_fail(R_BASE);
                    else if (drp_do == planned) begin
                        issue(1'b0, PLAN_ADDR, 16'd0);      // nothing to write: verify only
                        write_word <= planned;
                        state <= S_VERIFY;
                    end else begin
                        issue(1'b1, PLAN_ADDR, planned);
                        write_word <= planned;
                        state <= S_WRITE;
                    end
                end else if (timed_out) finish_fail(R_TIMEOUT);
            S_WRITE:
                if (drp_rdy) begin
                    if (abort || rst_src) state <= S_IDLE;
                    else begin
                        issue(1'b0, PLAN_ADDR, 16'd0);
                        state <= S_VERIFY;
                    end
                end else if (timed_out) finish_fail(R_TIMEOUT);
            S_VERIFY:
                if (drp_rdy) begin
                    verify_word <= drp_do;
                    if (abort || rst_src) state <= S_IDLE;
                    else if (drp_do != write_word) finish_fail(R_VERIFY);
                    else begin
                        drp_ok <= 1'b1;
                        state <= S_IDLE;
                    end
                end else if (timed_out) finish_fail(R_TIMEOUT);
            default:
                state <= S_IDLE;
        endcase
    end
endmodule
