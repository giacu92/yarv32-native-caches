`resetall
`timescale 1ns / 1ps
`default_nettype none

import yarv32_cache_pkg::*;

/**
 * Verilator testbench / top for the yarv32 cache subsystem.
 *
 * Classic bit-slice geometry: addr = {tag, set_idx, offset}, 11-bit tag,
 * 16-bit tag word, one tag word per set (TAG_ADDR_W = NBIT_SET_IDX +
 * TAG_BYTES_W in the DUT). Tag/data macro preloads below use the same
 * split, so a preload lands in the word the DUT actually looks up.
 *
 * Self-checking phases:
 *   A: I-cache hit  at ADDR_I_HIT (set 13, tag 0x3CD) with expected-rdata
 *      check
 *   D: I-port response-queue behavior: a read issued with rready=0 must be
 *      HELD (not lost), a second read must be accepted while the first is
 *      unconsumed (2 outstanding, I-port only), and both responses must
 *      come back in accept order. Runs before B because B's miss wedges the
 *      I-port until the Phase-4 unstall exists.
 *   B: I-cache miss at ADDR_I_MISS (set 0 preloaded with a VALID tag of a
 *      different value, so the phase exercises the tag comparator, not
 *      just the valid bit)
 *   C: D-cache hit  at ADDR_D_HIT with expected-rdata check
 *   E: I-cache hit on WAY 1 alone (per-way comparator + hit-way data mux)
 *   F: simultaneous I+D hits in the same cycle (per-cache independence)
 *   H: D-cache miss with BOTH ways valid (neither tag matches): the
 *      miss-detection half of an eviction. Eviction itself (victim
 *      selection, writeback) is TODO Phase 4 — a miss wedges the port
 *      until the Phase-4 unstall, so both miss phases run last.
 */

module sim_top;

    logic clk;
    logic rstn;
    logic sdram_clk;
    logic sdrc_clk;
    logic sdrc_rst_n;

    initial clk = 1'b0;
    initial forever #5 clk = ~clk;

    assign sdram_clk  = clk;
    assign sdrc_clk   = clk;
    assign sdrc_rst_n = rstn;

    mem_req_t        icache_req;
    mem_rsp_t        icache_rsp;
    mem_req_t        dcache_req;
    mem_rsp_t        dcache_rsp;

    wire             sdram_clk_o;
    wire             sdram_cke_o;
    wire             sdram_cs_n_o;
    wire             sdram_cas_n_o;
    wire             sdram_ras_n_o;
    wire             sdram_wen_n_o;
    wire      [ 3:0] sdram_dqm_o;
    wire      [10:0] sdram_addr_o;
    wire      [ 1:0] sdram_ba_o;
    wire      [31:0] sdram_dq_io;

    cache_cntrl u_dut (
        .clk_i        (clk),
        .rstn_i       (rstn),
        .icache_req_i (icache_req),
        .icache_rsp_o (icache_rsp),
        .dcache_req_i (dcache_req),
        .dcache_rsp_o (dcache_rsp),
        .sdram_clk_i  (sdram_clk),
        .sdrc_clk_i   (sdrc_clk),
        .sdrc_rst_n_i (sdrc_rst_n),
        .sdram_clk_o  (sdram_clk_o),
        .sdram_cke_o  (sdram_cke_o),
        .sdram_cs_n_o (sdram_cs_n_o),
        .sdram_cas_n_o(sdram_cas_n_o),
        .sdram_ras_n_o(sdram_ras_n_o),
        .sdram_wen_n_o(sdram_wen_n_o),
        .sdram_dqm_o  (sdram_dqm_o),
        .sdram_addr_o (sdram_addr_o),
        .sdram_ba_o   (sdram_ba_o),
        .sdram_dq_io  (sdram_dq_io)
    );

    // Geometry, derived exactly like cache_cntrl's localparams. Keep in
    // sync with the DUT (a hierarchical u_dut.<localparam> reference is not
    // usable in a constant context here).
    localparam int MEM_SIZE = 23;
    localparam int NBIT_OFFSET = 5;
    localparam int NBIT_SET_IDX = 7;
    localparam int NBIT_WAY = 1;
    localparam int TAG_FIELD_W = MEM_SIZE - NBIT_SET_IDX - NBIT_OFFSET;
    localparam int NBIT_TAG = TAG_FIELD_W + 2;
    localparam int TAG_DATA_W = ((NBIT_TAG + 7) / 8) * 8;

    localparam logic [22:0] ADDR_I_HIT = 23'h3C_D1A5;
    localparam logic [22:0] ADDR_I_MISS = 23'h00_2000;
    localparam logic [22:0] ADDR_D_HIT = 23'h00_0000;

    localparam logic [255:0] LINE_PATTERN =
        256'h8778_7667_6556_5445_4334_3223_2112_1001_DDEE_DDCC_BBAA_9988_7766_5544_3322_1100;

    // Both hit addresses have addr[4:3]=0, so the expected 64-bit response
    // is always doubleword 0 of the preloaded line.
    localparam logic [63:0] EXP_DW0 = LINE_PATTERN[63:0];

    // Phase-D second read: same line as ADDR_I_HIT, doubleword 1.
    localparam logic [22:0] ADDR_I_HIT_DW1 = ADDR_I_HIT + 23'd8;
    localparam logic [63:0] EXP_DW1 = LINE_PATTERN[127:64];

    // Phase-E way-1 hit: way 1 alone is valid in set 40 (tag 0x1AB), with
    // its own line pattern so a stuck-at-way-0 data mux is caught.
    localparam logic [22:0] ADDR_I_WAY1 = 23'h1AB500;
    localparam logic [255:0] LINE_PATTERN_W1 =
        256'hF0E1D2C3B4A5968778695A4B3C2D1E0FDEADBEEFCAFEBABE0123456789ABCDEF;
    localparam logic [63:0] EXP_W1_DW0 = LINE_PATTERN_W1[63:0];

    // Phase-H D-miss with BOTH ways valid: the requested tag (0x300) differs
    // from way 0's (0x111) and way 1's (0x222) in set 41 — only the tag
    // equality can rule out a hit on either way.
    localparam logic [22:0] ADDR_D_MISS2 = 23'h300520;

    localparam int DATA_WORD_I_WAY1 = int'(ADDR_I_WAY1[NBIT_OFFSET+:NBIT_SET_IDX]);

    // Data-macro word index (addr[NBIT_OFFSET +: NBIT_SET_IDX]): the data
    // macros are indexed by the raw CPU address, one 256-bit word per set.
    localparam int DATA_WORD_I_HIT = int'(ADDR_I_HIT[NBIT_OFFSET+:NBIT_SET_IDX]);
    localparam int DATA_WORD_D_HIT = int'(ADDR_D_HIT[NBIT_OFFSET+:NBIT_SET_IDX]);

    function automatic logic [NBIT_SET_IDX-1:0] set_of(input logic [22:0] addr);
        set_of = addr[NBIT_OFFSET+:NBIT_SET_IDX];
    endfunction

    function automatic logic [TAG_FIELD_W-1:0] tag_of(input logic [22:0] addr);
        tag_of = addr[MEM_SIZE-1:NBIT_OFFSET+NBIT_SET_IDX];
    endfunction

    function automatic logic [TAG_DATA_W-1:0] tag_word(input logic [22:0] addr);
        tag_word = {{(TAG_DATA_W - TAG_FIELD_W - 2) {1'b0}}, tag_of(addr), 1'b0, 1'b1};
    endfunction

    function automatic logic [TAG_DATA_W-1:0] tag_word_v(input logic [TAG_FIELD_W-1:0] t);
        tag_word_v = {{(TAG_DATA_W - TAG_FIELD_W - 2) {1'b0}}, t, 1'b0, 1'b1};
    endfunction

    initial begin
        $display("[sim_top] TAG_FIELD_W=%0d TAG_DATA_W=%0d", TAG_FIELD_W, TAG_DATA_W);
        $display("[sim_top] I-hit  addr=0x%0h set=%0d tag=0x%0h tagword=0x%0h data_word=%0d",
                 ADDR_I_HIT, set_of(ADDR_I_HIT), tag_of(ADDR_I_HIT), tag_word(ADDR_I_HIT),
                 DATA_WORD_I_HIT);
        $display("[sim_top] I-miss addr=0x%0h set=%0d tag=0x%0h", ADDR_I_MISS, set_of(ADDR_I_MISS),
                 tag_of(ADDR_I_MISS));
        $display("[sim_top] D-hit  addr=0x%0h set=%0d tag=0x%0h tagword=0x%0h data_word=%0d",
                 ADDR_D_HIT, set_of(ADDR_D_HIT), tag_of(ADDR_D_HIT), tag_word(ADDR_D_HIT),
                 DATA_WORD_D_HIT);
    end

    // Tag macro preload: one tag word per set, indexed by the plain set
    // index (the DUT shifts by TAG_BYTES_W itself; native_ram drops those
    // low bits as the intra-word byte select).
    initial begin
        // Way 0 holds a valid tag for the hit addresses, way 1 stays invalid.
        u_dut.gen_way[0].u_itag.mem[set_of(ADDR_I_HIT)] = tag_word(ADDR_I_HIT);
        u_dut.gen_way[1].u_itag.mem[set_of(ADDR_I_HIT)] = {TAG_DATA_W{1'b0}};
        u_dut.gen_way[0].u_icache.mem[DATA_WORD_I_HIT] = LINE_PATTERN;

        u_dut.gen_way[0].u_dtag.mem[set_of(ADDR_D_HIT)] = tag_word(ADDR_D_HIT);
        u_dut.gen_way[1].u_dtag.mem[set_of(ADDR_D_HIT)] = {TAG_DATA_W{1'b0}};
        u_dut.gen_way[0].u_dcache.mem[DATA_WORD_D_HIT] = LINE_PATTERN;

        // Phase-B miss set: a VALID tag whose value differs from the
        // requested one, so only the tag equality can rule out a hit.
        u_dut.gen_way[0].u_itag.mem[set_of(ADDR_I_MISS)] = {{(TAG_DATA_W - TAG_FIELD_W - 2) {1'b0}},
                                                            11'h555, 1'b0, 1'b1};
        u_dut.gen_way[1].u_itag.mem[set_of(ADDR_I_MISS)] = {TAG_DATA_W{1'b0}};

        // Phase-E way-1 hit set: way 1 valid with its own tag and line,
        // way 0 invalid.
        u_dut.gen_way[0].u_itag.mem[set_of(ADDR_I_WAY1)] = {TAG_DATA_W{1'b0}};
        u_dut.gen_way[1].u_itag.mem[set_of(ADDR_I_WAY1)] = tag_word(ADDR_I_WAY1);
        u_dut.gen_way[1].u_icache.mem[DATA_WORD_I_WAY1] = LINE_PATTERN_W1;

        // Phase-H D-miss set: BOTH ways valid, neither matching the
        // requested tag.
        u_dut.gen_way[0].u_dtag.mem[set_of(ADDR_D_MISS2)] = tag_word_v(11'h111);
        u_dut.gen_way[1].u_dtag.mem[set_of(ADDR_D_MISS2)] = tag_word_v(11'h222);
    end

    localparam int N_CYCLES = 300;
    integer error_count;
    integer wait_rsp;
    integer wait_fsm;

    initial begin
        error_count = 0;
        rstn        = 1'b0;
        icache_req  = '0;
        dcache_req  = '0;

        repeat (2) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);

        // ---- Phase A: I-cache hit. Poll the CPU-facing rvalid (the internal
        // hit signal is a one-cycle pulse per lookup, not a steady level).
        // ----
        icache_req.valid  = 1'b1;
        icache_req.we     = 1'b0;
        icache_req.addr   = {{(64 - 23) {1'b0}}, ADDR_I_HIT};
        icache_req.rready = 1'b1;

        wait_rsp          = 0;
        while (!icache_rsp.rvalid && wait_rsp < 20) begin
            @(posedge clk);
            wait_rsp = wait_rsp + 1;
        end
        if (!icache_rsp.rvalid) begin
            error_count = error_count + 1;
            $display("FAIL  A: no icache rvalid at 0x%0h within %0d cycles", ADDR_I_HIT, wait_rsp);
        end else if (icache_rsp.rdata !== EXP_DW0) begin
            error_count = error_count + 1;
            $display("FAIL  A: icache rdata at 0x%0h expected %h, got %h", ADDR_I_HIT, EXP_DW0,
                     icache_rsp.rdata);
        end else begin
            $display("PASS  A: icache HIT at 0x%0h (set=%0d rdata=%h, %0d cycles)", ADDR_I_HIT,
                     set_of(ADDR_I_HIT), icache_rsp.rdata, wait_rsp);
        end

        // ---- Phase D: I-port held response + 2 outstanding reads.
        // A is issued with rready=0: its response must be HELD in the
        // response queue, not lost. B (same line, next doubleword) is
        // issued while A is unconsumed — 2 outstanding reads, I-port only.
        // Both responses must arrive in order (A first, then B), and wready
        // must drop once both units are in flight.
        // ----
        icache_req.valid = 1'b0;  // drain Phase A's in-flight duplicates
        repeat (4) @(posedge clk);

        icache_req.valid  = 1'b1;
        icache_req.we     = 1'b0;
        icache_req.addr   = {{(64 - 23) {1'b0}}, ADDR_I_HIT};
        icache_req.rready = 1'b0;  // hold A's response
        @(posedge clk);  // A accepted
        icache_req.addr = {{(64 - 23) {1'b0}}, ADDR_I_HIT_DW1};
        @(posedge clk);  // B accepted while A is unconsumed
        icache_req.valid = 1'b0;  // stop issuing; A and B are in flight

        wait_rsp         = 0;
        while (!icache_rsp.rvalid && wait_rsp < 20) begin
            @(posedge clk);
            wait_rsp = wait_rsp + 1;
        end
        repeat (3) @(posedge clk);  // rready still 0: response must be held
        if (!icache_rsp.rvalid) begin
            error_count = error_count + 1;
            $display("FAIL  D1: icache response not held with rready=0");
        end else if (icache_rsp.rdata !== EXP_DW0) begin
            error_count = error_count + 1;
            $display("FAIL  D1: held icache rdata expected %h, got %h", EXP_DW0, icache_rsp.rdata);
        end else begin
            $display("PASS  D1: icache response held with rready=0 (rdata=%h)", icache_rsp.rdata);
        end
        if (icache_rsp.wready) begin
            error_count = error_count + 1;
            $display("FAIL  D2: wready high with 2 outstanding I-port reads");
        end else begin
            $display("PASS  D2: wready low with 2 outstanding I-port reads");
        end

        // Consume both, in accept order (A is held at the head).
        icache_req.rready = 1'b1;
        @(posedge clk);  // pops A; B must now be at the head
        if (!icache_rsp.rvalid || icache_rsp.rdata !== EXP_DW1) begin
            error_count = error_count + 1;
            $display(
                "FAIL  D3: second outstanding response missing/out of order (rvalid=%b rdata=%h)",
                icache_rsp.rvalid, icache_rsp.rdata);
        end else begin
            $display("PASS  D3: 2 outstanding reads returned in order (A=%h B=%h)", EXP_DW0,
                     EXP_DW1);
        end
        @(posedge clk);  // pops B; the queue must drain
        if (icache_rsp.rvalid) begin
            error_count = error_count + 1;
            $display("FAIL  D4: rvalid stuck after both responses consumed");
        end else begin
            $display("PASS  D4: response queue empty after both consumed");
        end
        repeat (2) @(posedge clk);

        // ---- Phase E: I-cache hit on WAY 1 (way 1 alone is valid in set
        // 40, with its own line pattern). Exercises the per-way tag
        // comparator and the hit-way data mux — a stuck-at-way-0 mux or a
        // comparator that ignores way 1 is caught by the rdata check.
        // ----
        icache_req.valid  = 1'b1;
        icache_req.addr   = {{(64 - 23) {1'b0}}, ADDR_I_WAY1};
        icache_req.rready = 1'b1;
        wait_rsp          = 0;
        while (!icache_rsp.rvalid && wait_rsp < 20) begin
            @(posedge clk);
            wait_rsp = wait_rsp + 1;
        end
        if (!icache_rsp.rvalid) begin
            error_count = error_count + 1;
            $display("FAIL  E: no icache rvalid at 0x%0h (way-1 hit)", ADDR_I_WAY1);
        end else if (icache_rsp.rdata !== EXP_W1_DW0) begin
            error_count = error_count + 1;
            $display("FAIL  E: way-1 icache rdata at 0x%0h expected %h, got %h", ADDR_I_WAY1,
                     EXP_W1_DW0, icache_rsp.rdata);
        end else begin
            $display("PASS  E: icache WAY-1 HIT at 0x%0h (set=%0d tag=%0h rdata=%h)", ADDR_I_WAY1,
                     set_of(ADDR_I_WAY1), tag_of(ADDR_I_WAY1), icache_rsp.rdata);
        end
        icache_req.valid = 1'b0;
        repeat (4) @(posedge clk);  // drain in-flight duplicates

        // ---- Phase F: simultaneous I+D hits — one request per cache in
        // the same cycle. Both must be accepted and both responses must
        // carry their own cache's data (per-cache independence).
        // ----
        icache_req.valid  = 1'b1;
        icache_req.addr   = {{(64 - 23) {1'b0}}, ADDR_I_HIT};
        icache_req.rready = 1'b1;
        dcache_req.valid  = 1'b1;
        dcache_req.we     = 1'b0;
        dcache_req.addr   = {{(64 - 23) {1'b0}}, ADDR_D_HIT};
        dcache_req.rready = 1'b1;

        wait_rsp          = 0;
        while (!icache_rsp.rvalid && wait_rsp < 20) begin
            @(posedge clk);
            wait_rsp = wait_rsp + 1;
        end
        wait_fsm = 0;
        while (!dcache_rsp.rvalid && wait_fsm < 20) begin
            @(posedge clk);
            wait_fsm = wait_fsm + 1;
        end
        if (!icache_rsp.rvalid || icache_rsp.rdata !== EXP_DW0) begin
            error_count = error_count + 1;
            $display("FAIL  F: simultaneous I response wrong (rvalid=%b rdata=%h)",
                     icache_rsp.rvalid, icache_rsp.rdata);
        end else if (!dcache_rsp.rvalid || dcache_rsp.rdata !== EXP_DW0) begin
            error_count = error_count + 1;
            $display("FAIL  F: simultaneous D response wrong (rvalid=%b rdata=%h)",
                     dcache_rsp.rvalid, dcache_rsp.rdata);
        end else begin
            $display("PASS  F: simultaneous I+D hits both served (I rdata=%h D rdata=%h)",
                     icache_rsp.rdata, dcache_rsp.rdata);
        end
        icache_req.valid = 1'b0;
        dcache_req.valid = 1'b0;
        repeat (4) @(posedge clk);  // drain

        // ---- Phase B: I-cache miss. The set is preloaded with a VALID tag
        // of a different value, so a broken comparator yields a hit loop
        // and the FSM never leaves S_IDLE (caught by the timeout).
        // ----
        icache_req.valid = 1'b1;  // Phase F cleared it; re-issue
        icache_req.we    = 1'b0;
        icache_req.addr  = {{(64 - 23) {1'b0}}, ADDR_I_MISS};
        wait_fsm         = 0;
        while (u_dut.state_q == 0 && wait_fsm < 30) begin
            @(posedge clk);
            wait_fsm = wait_fsm + 1;
        end
        if (u_dut.state_q == 0) begin
            error_count = error_count + 1;
            $display("FAIL  B: miss at 0x%0h never reached the FSM (S_IDLE for %0d cycles)",
                     ADDR_I_MISS, wait_fsm);
        end else begin
            $display("PASS  B: icache MISS at 0x%0h (FSM state=%0s after %0d cycles)", ADDR_I_MISS,
                     u_dut.state_q.name(), wait_fsm);
        end

        icache_req.valid = 1'b0;
        repeat (2) @(posedge clk);

        // ---- Phase C: D-cache hit ----
        dcache_req.valid  = 1'b1;
        dcache_req.we     = 1'b0;
        dcache_req.addr   = {{(64 - 23) {1'b0}}, ADDR_D_HIT};
        dcache_req.rready = 1'b1;
        wait_rsp          = 0;
        while (!dcache_rsp.rvalid && wait_rsp < 20) begin
            @(posedge clk);
            wait_rsp = wait_rsp + 1;
        end
        if (!dcache_rsp.rvalid) begin
            error_count = error_count + 1;
            $display("FAIL  C: no dcache rvalid at 0x%0h within %0d cycles", ADDR_D_HIT, wait_rsp);
        end else if (dcache_rsp.rdata !== EXP_DW0) begin
            error_count = error_count + 1;
            $display("FAIL  C: dcache rdata at 0x%0h expected %h, got %h", ADDR_D_HIT, EXP_DW0,
                     dcache_rsp.rdata);
        end else begin
            $display("PASS  C: dcache HIT at 0x%0h (set=%0d rdata=%h, %0d cycles)", ADDR_D_HIT,
                     set_of(ADDR_D_HIT), dcache_rsp.rdata, wait_rsp);
        end
        dcache_req.valid = 1'b0;

        // ---- Phase H: D-cache miss with BOTH ways valid (set 41: way 0
        // tag 0x111, way 1 tag 0x222, requested 0x300) — the miss-detection
        // half of an eviction scenario. The eviction itself (victim
        // selection, writeback, line commit, unstall) is TODO Phase 4, so
        // this only checks that neither valid-but-different tag produces a
        // false hit and the FSM takes the miss. Must run last: a miss
        // wedges the port until the Phase-4 unstall exists.
        // ----
        wait_fsm         = 0;
        while (u_dut.state_q != 0 && wait_fsm < 60) begin
            @(posedge clk);  // let any in-flight FSM transit settle
            wait_fsm = wait_fsm + 1;
        end
        repeat (4) @(posedge clk);  // drain Phase-C leftovers (rready=1 pops them)
        dcache_req.valid  = 1'b1;
        dcache_req.we     = 1'b0;
        dcache_req.addr   = {{(64 - 23) {1'b0}}, ADDR_D_MISS2};
        dcache_req.rready = 1'b1;
        wait_fsm          = 0;
        while (u_dut.state_q == 0 && !dcache_rsp.rvalid && wait_fsm < 30) begin
            @(posedge clk);
            wait_fsm = wait_fsm + 1;
        end
        if (dcache_rsp.rvalid) begin
            error_count = error_count + 1;
            $display("FAIL  H: FALSE HIT at 0x%0h (both ways valid, neither tag matches; rdata=%h)",
                     ADDR_D_MISS2, dcache_rsp.rdata);
        end else if (u_dut.state_q == 0) begin
            error_count = error_count + 1;
            $display("FAIL  H: miss at 0x%0h never reached the FSM (S_IDLE for %0d cycles)",
                     ADDR_D_MISS2, wait_fsm);
        end else begin
            $display("PASS  H: dcache MISS with both ways valid at 0x%0h (FSM state=%0s)",
                     ADDR_D_MISS2, u_dut.state_q.name());
        end
        dcache_req.valid = 1'b0;

        if (error_count == 0) $display("\n[sim_top] ALL CHECKS PASSED");
        else $display("\n[sim_top] %0d CHECK(S) FAILED", error_count);

        $finish;
    end

    initial begin
        repeat (N_CYCLES) @(posedge clk);
        $display("[sim_top] watchdog timeout after %0d cycles (response path is a TODO)", N_CYCLES);
        $finish;
    end

    initial begin
        $dumpfile("sim_top.vcd");
        $dumpvars(0, sim_top);
    end

endmodule

`resetall
