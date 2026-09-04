`resetall
`timescale 1ns / 1ps
`default_nettype none

import yarv32_cache_pkg::*;

/**
 * Cache built-in self test — board bring-up traffic generator.
 *
 * Drives the cache controller's CPU-facing native ports (`mem_req_t` /
 * `mem_rsp_t`) with a fixed, self-checking sequence so an FPGA build has
 * something real to exercise before a CPU is attached. Without it the
 * synthesizer would prune the whole cache subsystem (no driver on the
 * request ports, no consumer of the responses).
 *
 * Sequence (all on the D-port unless stated):
 *   1. STORE   — N_ADDR posted 64-bit stores of a per-index pattern.
 *      Every address maps to the SAME set (stride = N_SETS * 2**CL_SIZE),
 *      with a different tag each, so a 2-way cache takes N_ADDR store
 *      misses, write-allocates them dirty, and evicts all but the last
 *      two through the SDRAM writeback path.
 *   2. LOAD    — the same N_ADDR addresses read back and compared against
 *      the patterns. Everything but the last two lines must come back
 *      from SDRAM, so a pass proves writeback + refill round-trips
 *      through the real chip.
 *   3. IFETCH  — a few I-port reads from an untouched region. Data is
 *      whatever the SDRAM holds at power-on, so only response liveness is
 *      checked (the read must complete); this keeps the I-side of the
 *      controller in the netlist and exercises the second port.
 *   4. DONE    — `pass_o` / `fail_o` hold their final value, and
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

    // I-cache port (read-only traffic)
    output mem_req_t icache_req_o,
    input  mem_rsp_t icache_rsp_i,

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
    //   [3] rsp.wready  [2] rsp.rvalid  [1] req.valid  [0] req.we
    // With the hang hold below these are the values AT the stall, not
    // after it has been abandoned.
    output wire [3:0] dbg_hs_o
);

    // Byte stride between two addresses of the same set: one full pass
    // over every set. Consecutive test addresses differ only in the tag.
    localparam int SET_STRIDE = N_SETS * (1 << CL_SIZE);

    // Doubleword-aligned offset inside the line (64-bit accesses).
    localparam int LINE_OFFSET = 8;

    // I-port region: far from the D-port addresses so the two never share
    // a line (the caches are not coherent with each other).
    localparam int unsigned IFETCH_BASE = 32'h0040_0000;

    localparam int IDX_W = (N_ADDR > N_FETCH) ? $clog2(N_ADDR) : $clog2(N_FETCH);

    // -------------------------------------------------------------------
    // Test vectors
    // -------------------------------------------------------------------

    // Address under test for index i, and the pattern stored there.
    function automatic logic [MEM_WIDTH-1:0] test_addr(input logic [IDX_W-1:0] i);
        test_addr = MEM_WIDTH'(i * SET_STRIDE + LINE_OFFSET);
    endfunction

    function automatic logic [MEM_WIDTH-1:0] test_data(input logic [IDX_W-1:0] i);
        test_data = {32'h5A5A_0000 | 32'(i), 32'hCAFE_0000 | 32'(i)};
    endfunction

    // -------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------

    typedef enum logic [2:0] {
        S_RESET,     // wait a few cycles after reset before the first request
        S_STORE,     // issue store i, wait for accept
        S_LOAD_REQ,  // issue load i, wait for accept
        S_LOAD_RSP,  // wait for the read response, compare
        S_FETCH_REQ, // issue I-port read i, wait for accept
        S_FETCH_RSP, // wait for the I-port response (liveness only)
        S_DONE
    } state_e;

    state_e state_q, state_d;

    logic [IDX_W-1:0] idx_q, idx_d;
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
    mem_req_t icache_req;
    mem_req_t dcache_req;

    always_comb begin
        state_d      = state_q;
        idx_d        = idx_q;
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
                wdog_d  = '0;
                idx_d   = '0;
                state_d = S_STORE;
            end

            // Posted store: accepted on valid && wready, no response.
            S_STORE: begin
                dcache_req.valid = 1'b1;
                dcache_req.we    = 1'b1;
                dcache_req.addr  = test_addr(idx_q);
                dcache_req.wdata = test_data(idx_q);
                dcache_req.wstrb = {STRB_WIDTH{1'b1}};
                if (dcache_rsp_i.wready) begin
                    wdog_d = '0;
                    if (int'(idx_q) == N_ADDR - 1) begin
                        idx_d   = '0;
                        state_d = S_LOAD_REQ;
                    end else begin
                        idx_d = idx_q + 1'b1;
                    end
                end
            end

            S_LOAD_REQ: begin
                dcache_req.valid  = 1'b1;
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
                    if (dcache_rsp_i.rdata != test_data(idx_q)) begin
                        fail_d = 1'b1;
                        if (!fail_q) begin
                            fail_code_d  = FAIL_MISMATCH;
                            fail_state_d = dbg_state_i;
                            fail_stage_d = 4'(state_q);
                            fail_dport_d = dbg_dport_i;
                        end
                    end
                    if (int'(idx_q) == N_ADDR - 1) begin
                        idx_d   = '0;
                        state_d = S_FETCH_REQ;
                    end else begin
                        idx_d   = idx_q + 1'b1;
                        state_d = S_LOAD_REQ;
                    end
                end
            end

            S_FETCH_REQ: begin
                icache_req.valid  = 1'b1;
                icache_req.addr   = MEM_WIDTH'(IFETCH_BASE) + MEM_WIDTH'(idx_q * SET_STRIDE);
                icache_req.rready = 1'b1;
                if (icache_rsp_i.wready) begin
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
    assign dbg_hs_o = {dcache_rsp_i.wready, dcache_rsp_i.rvalid, dcache_req.valid, dcache_req.we};

    assign busy_o = (state_q != S_DONE) && !hung_q;
    assign pass_o = (state_q == S_DONE) && !fail_q;
    assign fail_o = fail_q && ((state_q == S_DONE) || hung_q);

endmodule

`resetall
