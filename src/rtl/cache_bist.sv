`resetall
`timescale 1ns / 1ps
`default_nettype none

import yarv32_cache_pkg::*;

/**
 * Cache built-in self test — board bring-up traffic generator.
 *
 * Drives the cache controller's CPU-facing ports (the yarv32-uc interface:
 * read-only 64-bit `ifetch_*` on the I side, byte-strobed 32-bit `mem_*` on
 * the D side) with a fixed, self-checking sequence so an FPGA build has
 * something real to exercise before a CPU is attached. Without it the
 * synthesizer would prune the whole cache subsystem (no driver on the
 * request ports, no consumer of the responses).
 *
 * Sequence (all on the D-port unless stated):
 *   1. STORE   — N_ADDR posted 32-bit word stores of a per-index pattern.
 *      Every address maps to the SAME set (stride = N_SETS * 2**CL_SIZE),
 *      with a different tag each, so a 2-way cache takes N_ADDR store
 *      misses, write-allocates them dirty, and evicts all but the last
 *      two through the SDRAM writeback path. The word offset inside the
 *      line advances with the index, so the D-port word select is used at
 *      every position rather than one fixed lane.
 *   2. PATCH   — the same N_ADDR addresses stored again, TWICE each, with
 *      a per-index PARTIAL byte strobe. The first has been evicted by
 *      now, so it lands as a store miss merged into the refilled line;
 *      the second lands as a store hit merged into the resident line.
 *      Those are the design's two byte-merge paths and this is their only
 *      board coverage. The expected value is a byte-wise mux of the three
 *      patterns, defined no matter what the device powered up holding.
 *   3. LOAD    — the same N_ADDR addresses read back and compared against
 *      that merge, each address TWICE in a row. The first read must come
 *      from SDRAM (the set holds only N_WAY of the N_ADDR lines by then),
 *      so a pass proves writeback + refill round-trips through the real
 *      chip; the second finds the line resident and so covers the hit
 *      response path, whose word-select mux the miss path never uses.
 *   4. IFETCH  — a few I-port reads from an untouched region. Data is
 *      whatever the SDRAM holds at power-on, so only response liveness is
 *      checked (the read must complete); this keeps the I-side of the
 *      controller in the netlist and exercises the second port.
 *   5. DONE    — `pass_o` / `fail_o` hold their final value, and
 *      `fail_code_o` says WHY: data mismatch, D-port watchdog (the SDRAM
 *      round trip stopped answering) or I-port watchdog.
 *
 * A watchdog fails the test instead of hanging: a board that stops
 * responding shows "fail", not a dark, indistinguishable "still running".
 *
 * Naming: ports use *_i/_o; internals no prefix; flops _q.
 */

module cache_bist #(
    // Main memory size (must match cache_cntrl's MEM_SIZE)
    parameter int MEM_SIZE = 23,
    // Cache line size in bits (must match cache_cntrl's CL_SIZE)
    parameter int CL_SIZE  = 5,
    // Number of sets per cache (cache_cntrl's derived N_SETS)
    parameter int N_SETS   = 128,
    // Number of test addresses. All land in the same set, so anything
    // above N_WAY forces evictions.
    parameter int N_ADDR   = 8,
    // Number of I-port fetches in the IFETCH stage
    parameter int N_FETCH  = 4,
    // Watchdog: cycles a single transaction may take before the test is
    // declared failed. 2**20 at 50 MHz is ~21 ms, orders of magnitude
    // above a refill (~100 cycles) even with refresh collisions.
    parameter int WDOG_W   = 20
) (
    input wire clk_i,
    input wire rstn_i,

    // I-cache port (read-only fetch traffic, 64-bit)
    output ifetch_req_t icache_req_o,
    input  ifetch_rsp_t icache_rsp_i,

    // D-cache port (store + load traffic)
    output mem_req_t dcache_req_o,
    input  mem_rsp_t dcache_rsp_i,

    // Miss-FSM state of the cache under test (cache_cntrl.dbg_state_o),
    // latched at the failure: a watchdog failure then says WHERE the
    // transfer got stuck, not just that it did.
    input wire [3:0] dbg_state_i,

    // D-port occupancy bits of the cache under test
    // (cache_cntrl.dbg_dport_o), latched at the failure alongside the
    // rest: a port that never accepted a request and a port whose response
    // never came look identical from the outside, and these tell them
    // apart.
    input wire [3:0] dbg_dport_i,

    // Status
    output wire       busy_o,        // test still running
    output wire       pass_o,        // finished, every check matched
    output wire       fail_o,        // finished, at least one check failed
    // Why it failed, latched at the FIRST failure (see fail_code_e). On a
    // board the LEDs are the only console there is, so the distinction
    // between "the data came back wrong" and "the port never answered" has
    // to leave the die.
    output wire [1:0] fail_code_o,
    output wire [3:0] fail_state_o,  // dbg_state_i sampled at the failure
    output wire [3:0] fail_stage_o,  // the stage the test hung in
    output wire [3:0] fail_dport_o,  // dbg_dport_i sampled at the failure

    // Live progress, for the debug UART: which stage the test is in and
    // which vector it is on. A hang prints the same pair forever, which is
    // what says where it stopped.
    output wire [3:0] dbg_stage_o,
    output wire [3:0] dbg_idx_o,

    // The D-port handshake as this master sees it, live:
    //   [3] rsp.wready  [2] rsp.rvalid  [1] req.wvalid  [0] req.we
    // With the hang hold below these are the values AT the stall, not
    // after it has been abandoned.
    output wire [3:0] dbg_hs_o
);

    // Byte stride between two addresses of the same set: one full pass
    // over every set. Consecutive test addresses differ only in the tag.
    localparam int SET_STRIDE = N_SETS * (1 << CL_SIZE);

    // 32-bit words per cache line. The test walks the offset across all of
    // them (see test_addr) so the controller's D-port word select is
    // exercised at every position instead of one fixed lane.
    localparam int WORDS_PER_LINE = (1 << CL_SIZE) / 4;

    // I-port region: far from the D-port addresses so the two never share
    // a line (the caches are not coherent with each other).
    localparam int unsigned IFETCH_BASE = 32'h0040_0000;

    localparam int IDX_W = (N_ADDR > N_FETCH) ? $clog2(N_ADDR) : $clog2(N_FETCH);

    // -------------------------------------------------------------------
    // Test vectors
    // -------------------------------------------------------------------

    // Address under test for index i. The line (tag) changes with i so the
    // set fills and evicts; the word offset WITHIN the line also changes
    // with i, so consecutive indices land on different word selects.
    function automatic logic [NATIVE_ADDR_W-1:0] test_addr(input logic [IDX_W-1:0] i);
        test_addr = NATIVE_ADDR_W'(i * SET_STRIDE + 4 * (int'(i) % WORDS_PER_LINE));
    endfunction

    // Full-word pattern written first. Deliberately NOT in the 0xCAFE_xxxx
    // family: sdram_model powers up filled with 32'hCAFE_0000 | word_index,
    // so a CAFE pattern at index 0 is bit-identical to the untouched device
    // content and a read that returns the wrong word would still compare
    // equal. Both halves carry i (once inverted) so a wrong word select or
    // a stale line differs in every byte lane.
    function automatic logic [LSU_DATA_W-1:0] test_data(input logic [IDX_W-1:0] i);
        test_data = {16'h5A5A, 8'(i), ~8'(i)};
    endfunction

    // Two further partially strobed writes to the same address. The first
    // takes a store MISS (the line has been evicted by then) and so goes
    // through the write-allocate merge into the refilled line; the second
    // follows immediately, finds the line resident, and so goes through
    // the store-HIT merge into the way's registered output. Those are two
    // different merge paths, and this is the only place either is
    // exercised on a board.
    function automatic logic [LSU_DATA_W-1:0] test_patch(input logic [IDX_W-1:0] i);
        test_patch = {16'hA5A5, ~8'(i), 8'(i)};
    endfunction

    function automatic logic [LSU_DATA_W-1:0] test_patch2(input logic [IDX_W-1:0] i);
        test_patch2 = {16'h3C3C, 8'(i), ~8'(i)};
    endfunction

    // Byte strobes for those two writes: i+1 and i+2, so every index uses
    // a different mask, the two masks overlap only partially, and neither
    // is ever all-zero or all-ones for i < 8 (which is what keeps both
    // "written" and "untouched" bytes present in the expected value).
    function automatic logic [LSU_STRB_W-1:0] test_strb(input logic [IDX_W-1:0] i);
        test_strb = LSU_STRB_W'(int'(i) + 1);
    endfunction

    function automatic logic [LSU_STRB_W-1:0] test_strb2(input logic [IDX_W-1:0] i);
        test_strb2 = LSU_STRB_W'(int'(i) + 2);
    endfunction

    // A byte strobe widened to a bit mask. Spelled out lane by lane (the
    // LSU is 32 bits, so there are four) instead of looping over
    // LSU_STRB_W: sv2v renders a loop that assigns into a part-select of
    // the function's own return value as a block reg, which yosys then
    // rejects outright -- and make lint-yosys is a gate for the board
    // build.
    function automatic logic [LSU_DATA_W-1:0] strb_mask(input logic [LSU_STRB_W-1:0] s);
        strb_mask = {{8{s[3]}}, {8{s[2]}}, {8{s[1]}}, {8{s[0]}}};
    endfunction

    // What the address must hold after all three writes: the base word,
    // with the two patches applied in order over their own strobes. This
    // is fully defined by the writes themselves, so it holds whatever the
    // device powered up containing.
    function automatic logic [LSU_DATA_W-1:0] test_merge1(input logic [IDX_W-1:0] i);
        test_merge1 = (test_patch(i) & strb_mask(test_strb(i))) |
            (test_data(i) & ~strb_mask(test_strb(i)));
    endfunction

    function automatic logic [LSU_DATA_W-1:0] test_expect(input logic [IDX_W-1:0] i);
        test_expect = (test_patch2(i) & strb_mask(test_strb2(i))) |
            (test_merge1(i) & ~strb_mask(test_strb2(i)));
    endfunction

    // -------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------

    typedef enum logic [2:0] {
        S_RESET,     // wait a few cycles after reset before the first request
        S_STORE,     // issue full-word store i, wait for accept
        S_PATCH,     // issue partially strobed store i, wait for accept
        S_LOAD_REQ,  // issue load i, wait for accept
        S_LOAD_RSP,  // wait for the read response, compare
        S_FETCH_REQ, // issue I-port read i, wait for accept
        S_FETCH_RSP, // wait for the I-port response (liveness only)
        S_DONE
    } state_e;

    state_e state_q, state_d;

    logic [IDX_W-1:0] idx_q, idx_d;

    // Each address is loaded twice in a row. The first load takes a miss
    // (the set holds only N_WAY of the N_ADDR lines by then) and is
    // answered off the refill path; the second finds the line resident and
    // is answered off the cache array's registered output -- a different
    // word-select mux, which a single-load pass never reaches at all.
    logic repeat_q, repeat_d;

    logic fail_q, fail_d;

    // Failure classification. FAIL_MISMATCH means the cache answered with
    // the wrong data (refill/writeback/merge path); the two watchdog codes
    // mean a port stopped answering entirely, split by which port, since
    // the D-port exercises the SDRAM round trip and the I-port only reads.
    typedef enum logic [1:0] {
        FAIL_NONE     = 2'b00,
        FAIL_MISMATCH = 2'b01,
        FAIL_WDOG_D   = 2'b10,
        FAIL_WDOG_I   = 2'b11
    } fail_code_e;

    fail_code_e fail_code_q, fail_code_d;

    // Hang hold. A watchdog failure used to fall through to S_DONE, which
    // drops the stalled request and lets the port recover — so every LIVE
    // field then described a cache that was no longer stuck, and could
    // contradict the fields latched at the failure (seen on the board: a
    // latched "lookup launched" next to a live lookup count of zero).
    // Holding the stage instead keeps the request asserted and the cache in
    // exactly the state that hung, so the periodic report IS the stall.
    logic hung_q, hung_d;

    logic [3:0] fail_state_q, fail_state_d;
    logic [3:0] fail_stage_q, fail_stage_d;
    logic [3:0] fail_dport_q, fail_dport_d;
    logic [WDOG_W-1:0] wdog_q, wdog_d;

    // Request drivers (combinational off the state).
    ifetch_req_t icache_req;
    mem_req_t    dcache_req;

    always_comb begin
        state_d      = state_q;
        idx_d        = idx_q;
        repeat_d     = repeat_q;
        fail_d       = fail_q;
        fail_code_d  = fail_code_q;
        hung_d       = hung_q;
        fail_state_d = fail_state_q;
        fail_stage_d = fail_stage_q;
        fail_dport_d = fail_dport_q;
        // The watchdog counts cycles spent on the current transaction and
        // is cleared whenever the FSM makes progress.
        wdog_d       = hung_q ? wdog_q : (wdog_q + 1'b1);

        icache_req   = '0;
        dcache_req   = '0;

        unique case (state_q)
            S_RESET: begin
                wdog_d   = '0;
                idx_d    = '0;
                repeat_d = 1'b0;
                state_d  = S_STORE;
            end

            // Posted store: accepted on wvalid && wready, no response.
            S_STORE: begin
                dcache_req.wvalid = 1'b1;
                dcache_req.we     = 1'b1;
                dcache_req.addr   = test_addr(idx_q);
                dcache_req.wdata  = test_data(idx_q);
                dcache_req.wstrb  = {LSU_STRB_W{1'b1}};
                if (dcache_rsp_i.wready) begin
                    wdog_d = '0;
                    if (int'(idx_q) == N_ADDR - 1) begin
                        idx_d   = '0;
                        state_d = S_PATCH;
                    end else begin
                        idx_d = idx_q + 1'b1;
                    end
                end
            end

            // Partially strobed posted store over the same address. By now
            // the full-word store of this index has been evicted (N_ADDR
            // lines through N_WAY ways), so this one takes a store miss and
            // merges into the REFILLED line; the write-allocate merge and
            // the writeback that produced the line are both on the hook for
            // the compare in S_LOAD_RSP.
            S_PATCH: begin
                dcache_req.wvalid = 1'b1;
                dcache_req.we     = 1'b1;
                dcache_req.addr   = test_addr(idx_q);
                dcache_req.wdata  = repeat_q ? test_patch2(idx_q) : test_patch(idx_q);
                dcache_req.wstrb  = repeat_q ? test_strb2(idx_q) : test_strb(idx_q);
                if (dcache_rsp_i.wready) begin
                    wdog_d = '0;
                    if (!repeat_q) begin
                        // Same address again: this one is a store hit.
                        repeat_d = 1'b1;
                    end else if (int'(idx_q) == N_ADDR - 1) begin
                        idx_d    = '0;
                        repeat_d = 1'b0;
                        state_d  = S_LOAD_REQ;
                    end else begin
                        idx_d    = idx_q + 1'b1;
                        repeat_d = 1'b0;
                    end
                end
            end

            S_LOAD_REQ: begin
                dcache_req.wvalid = 1'b1;
                dcache_req.addr   = test_addr(idx_q);
                dcache_req.rready = 1'b1;
                if (dcache_rsp_i.wready) begin
                    wdog_d  = '0;
                    state_d = S_LOAD_RSP;
                end
            end

            S_LOAD_RSP: begin
                dcache_req.rready = 1'b1;
                if (dcache_rsp_i.rvalid) begin
                    wdog_d = '0;
                    if (dcache_rsp_i.rdata != test_expect(idx_q)) begin
                        fail_d = 1'b1;
                        if (!fail_q) begin
                            fail_code_d  = FAIL_MISMATCH;
                            fail_state_d = dbg_state_i;
                            fail_stage_d = 4'(state_q);
                            fail_dport_d = dbg_dport_i;
                        end
                    end
                    if (!repeat_q) begin
                        // Same address again, this time as a hit.
                        repeat_d = 1'b1;
                        state_d  = S_LOAD_REQ;
                    end else if (int'(idx_q) == N_ADDR - 1) begin
                        idx_d   = '0;
                        state_d = S_FETCH_REQ;
                    end else begin
                        idx_d    = idx_q + 1'b1;
                        repeat_d = 1'b0;
                        state_d  = S_LOAD_REQ;
                    end
                end
            end

            S_FETCH_REQ: begin
                icache_req.valid  = 1'b1;
                icache_req.addr   = IFETCH_BASE + NATIVE_ADDR_W'(idx_q * SET_STRIDE);
                icache_req.rready = 1'b1;
                if (icache_rsp_i.ready) begin
                    wdog_d  = '0;
                    state_d = S_FETCH_RSP;
                end
            end

            // Liveness only: SDRAM content at this address is whatever the
            // chip powered up with, so there is nothing to compare against.
            S_FETCH_RSP: begin
                icache_req.rready = 1'b1;
                if (icache_rsp_i.rvalid) begin
                    wdog_d = '0;
                    if (int'(idx_q) == N_FETCH - 1) begin
                        state_d = S_DONE;
                    end else begin
                        idx_d   = idx_q + 1'b1;
                        state_d = S_FETCH_REQ;
                    end
                end
            end

            S_DONE: begin
                wdog_d = '0;
            end

            default: state_d = S_RESET;
        endcase

        // Watchdog expiry is a failure, not a hang: a port that never
        // answers must be visible on the LEDs.
        if (&wdog_q && !hung_q) begin
            fail_d = 1'b1;
            // state_d is deliberately left alone: the stage that hung
            // keeps driving its request (see the hang-hold note above).
            hung_d = 1'b1;
            if (!fail_q) begin
                fail_code_d = (state_q == S_FETCH_REQ || state_q == S_FETCH_RSP) ? FAIL_WDOG_I :
                    FAIL_WDOG_D;
                fail_state_d = dbg_state_i;
                fail_stage_d = 4'(state_q);
                fail_dport_d = dbg_dport_i;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            state_q      <= S_RESET;
            idx_q        <= '0;
            repeat_q     <= 1'b0;
            fail_q       <= 1'b0;
            hung_q       <= 1'b0;
            fail_code_q  <= FAIL_NONE;
            fail_state_q <= '0;
            fail_stage_q <= '0;
            fail_dport_q <= '0;
            wdog_q       <= '0;
        end else begin
            state_q      <= state_d;
            idx_q        <= idx_d;
            repeat_q     <= repeat_d;
            fail_q       <= fail_d;
            hung_q       <= hung_d;
            fail_code_q  <= fail_code_d;
            fail_state_q <= fail_state_d;
            fail_stage_q <= fail_stage_d;
            fail_dport_q <= fail_dport_d;
            wdog_q       <= wdog_d;
        end
    end

    assign icache_req_o = icache_req;
    assign dcache_req_o = dcache_req;

    assign fail_code_o = fail_code_q;
    assign fail_state_o = fail_state_q;
    assign fail_stage_o = fail_stage_q;
    assign fail_dport_o = fail_dport_q;
    assign dbg_stage_o = 4'(state_q);
    assign dbg_idx_o = 4'(idx_q);
    assign dbg_hs_o = {dcache_rsp_i.wready, dcache_rsp_i.rvalid, dcache_req.wvalid, dcache_req.we};

    assign busy_o = (state_q != S_DONE) && !hung_q;
    assign pass_o = (state_q == S_DONE) && !fail_q;
    assign fail_o = fail_q && ((state_q == S_DONE) || hung_q);

endmodule

`resetall
