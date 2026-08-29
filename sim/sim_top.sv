`resetall
`timescale 1ns / 1ps
`default_nettype none

import yarv32_cache_pkg::*;

/**
 * Verilator testbench / top for the yarv32 cache subsystem.
 *
 * Compiles with `verilator --binary --timing --trace` (delays and event
 * waits rely on --timing). Instantiates `cache_cntrl` and a behavioral
 * SDRAM controller stub (the real Gowin IP is not Verilator-simulatable;
 * see sim/sdram_stub.sv).
 *
 * Preload (sim-only, no RTL change)
 * --------------------------------
 * The cache data/tag macros are `native_ram` instances whose `mem` arrays
 * are reachable hierarchically from the testbench. We poke them directly so
 * a known line + tag is present before any request:
 *   - I-tag/D-tag way 0, set 0: valid=1, tag=0, dirty=0.
 *   - I-cache/D-cache data way 0, set 0: a recognizable 256-bit pattern.
 * Way 1 is left invalid, so only way 0 can hit -> icache_way_hit[0]=1.
 * This lets us exercise the combinational tag-compare / hit-detection path
 * (the part of the cache that is actually implemented) and contrast it
 * with a miss.
 *
 * What this exercises today
 * ------------------------
 * The cache's CPU-facing response path (icache_rsp_o/dcache_rsp_o) and the
 * hit/way-select datapath (imem_req/dmem_req) are still TODOs, so a hit
 * does NOT return data to the CPU and a miss never unstalls. The meaningful
 * checks are therefore on the implemented logic:
 *   - icache_hit / dcache_hit assert on a matching, valid tag;
 *   - a same-set, different-tag address misses (hit=0) and the miss FSM
 *     leaves S_IDLE (S_ARBITRATE -> S_REFILL_REQ -> S_REFILL_WAIT ->
 *     S_UPDATE_TAG, served by the stub).
 *
 * Plusargs +IINIT / +DINIT (used by the top-level `make sw-run`) are parsed
 * and echoed but are no-ops here (preload is done hierarchically above).
 *
 * Naming: ports *_i/_o per project convention; internals no prefix; flops _q.
 */

module sim_top;

    // -----------------------------------------------------------------
    // Clock & reset (10 ns period). --timing enables the delays below.
    // -----------------------------------------------------------------
    logic clk;
    logic rstn;
    logic sdram_clk;
    logic sdrc_clk;
    logic sdrc_rst_n;

    initial clk = 1'b0;
    initial forever #5 clk = ~clk;

    // Single clock domain for the sim; the SDRAM controller shares it.
    assign sdram_clk  = clk;
    assign sdrc_clk   = clk;
    assign sdrc_rst_n = rstn;

    // -----------------------------------------------------------------
    // DUT + interfaces
    // -----------------------------------------------------------------
    mem_req_t        icache_req;
    mem_rsp_t        icache_rsp;
    mem_req_t        dcache_req;
    mem_rsp_t        dcache_rsp;

    // External SDRAM pins from the controller — left open (the stub is
    // instantiated inside cache_cntrl and drives these to inert defaults).
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

    // -----------------------------------------------------------------
    // Plusargs (echo only).
    // -----------------------------------------------------------------
    string iinit, dinit;
    initial begin
        if ($value$plusargs("IINIT=%s", iinit))
            $display("[sim_top] +IINIT=%0s (preload is hierarchical; ignored)", iinit);
        if ($value$plusargs("DINIT=%s", dinit))
            $display("[sim_top] +DINIT=%0s (preload is hierarchical; ignored)", dinit);
    end

    // -----------------------------------------------------------------
    // Hierarchical preload of the cache macros (sim-only). Done at time 0
    // before the request interface is driven; BSRAM contents are not reset,
    // so these persist across the reset deassertion below.
    //
    // Tag word layout (from cache_cntrl): rdata[0]=valid, [1]=dirty,
    // [2+:TAG_FIELD_W]=tag. With MEM_SIZE=23, NBIT_SET_IDX=7, CL_SIZE=5:
    //   NBIT_TAG = 13, TAG_FIELD_W = 11, tag word = 16 bits.
    // Set 0, tag 0, valid, clean -> 16'h0001.
    //
    // Address -> tag-word mapping: the tag macro is addressed by the set
    // index bits [6:1] (bit [0] of set_idx is the byte-within-word bit,
    // currently unused by native_ram's decode). For the addresses below
    // (set 0), word_addr = 0.
    // -----------------------------------------------------------------
    localparam logic [15:0] TAG_VALID_CLEAN_TAG0 = 16'h0001;
    localparam logic [255:0] LINE_PATTERN =
        256'h8778_7667_6556_5445_4334_3223_2112_1001_DDEE_DDCC_BBAA_9988_7766_5544_3322_1100;

    initial begin
        // I-cache: way 0 holds set 0 with a valid tag 0; way 1 invalid.
        u_dut.gen_way[0].u_itag.mem[0]    = TAG_VALID_CLEAN_TAG0;
        u_dut.gen_way[0].u_itag.mem[13]   = 16'hF35;  //for icache_req.addr = 0x003c_d1af
        u_dut.gen_way[1].u_itag.mem[0]    = 16'h0000;
        u_dut.gen_way[0].u_icache.mem[0]  = LINE_PATTERN;
        u_dut.gen_way[0].u_icache.mem[13] = LINE_PATTERN;
        // D-cache: same, so a D-cache read at addr 0 hits.
        u_dut.gen_way[0].u_dtag.mem[0]    = TAG_VALID_CLEAN_TAG0;
        u_dut.gen_way[1].u_dtag.mem[0]    = 16'h0000;
        u_dut.gen_way[0].u_dcache.mem[0]  = LINE_PATTERN;
    end

    // -----------------------------------------------------------------
    // Stimulus + checks. error_count gates the final $finish status.
    // -----------------------------------------------------------------
    localparam int N_CYCLES = 300;
    integer error_count;
    logic   hit_sample;

    initial begin
        error_count = 0;
        rstn        = 1'b0;
        icache_req  = '0;
        dcache_req  = '0;

        // Reset.
        repeat (2) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);

        // ---- Phase A: I-cache HIT at addr 0 (set 0, tag 0) ----
        icache_req.valid  = 1'b1;
        icache_req.we     = 1'b0;
        icache_req.addr   = 64'h003c_d1af;
        icache_req.rready = 1'b1;

        repeat (5) @(posedge clk);  // let the tag lookup return
        hit_sample = u_dut.icache_hit;

        if (hit_sample !== 1'b1) begin
            error_count = error_count + 1;
            $display("FAIL  A: icache_hit at addr 0 expected 1, got %0b", hit_sample);
        end else begin
            $display("PASS  A: icache HIT at addr 0 (way_hit=%b)", u_dut.icache_way_hit);
        end

        // ---- Phase B: I-cache MISS — same set, different tag (addr 0x2000 -> tag 2) ----
        icache_req.addr = 64'h0000_2000;
        repeat (5) @(posedge clk);
        hit_sample = u_dut.icache_hit;
        if (hit_sample !== 1'b0) begin
            error_count = error_count + 1;
            $display("FAIL  B: icache_hit at addr 0x2000 expected 0, got %0b", hit_sample);
        end else if (u_dut.state_q == 3'd0  /* S_IDLE */) begin
            error_count = error_count + 1;
            $display("FAIL  B: miss did not start the FSM (still S_IDLE)");
        end else begin
            $display("PASS  B: icache MISS at addr 0x2000 (hit=0, FSM state=%0s)",
                     u_dut.state_q.name());
        end

        // Stop the I-cache request so it does not keep firing misses.
        icache_req.valid = 1'b0;
        repeat (2) @(posedge clk);

        // ---- Phase C: D-cache HIT at addr 0 (read) ----
        dcache_req.valid  = 1'b1;
        dcache_req.we     = 1'b0;
        dcache_req.addr   = 64'h0000_0000;
        dcache_req.rready = 1'b1;
        repeat (5) @(posedge clk);
        hit_sample = u_dut.dcache_hit;
        if (hit_sample !== 1'b1) begin
            error_count = error_count + 1;
            $display("FAIL  C: dcache_hit at addr 0 expected 1, got %0b", hit_sample);
        end else begin
            $display("PASS  C: dcache HIT at addr 0 (way_hit=%b)", u_dut.dcache_way_hit);
        end
        dcache_req.valid = 1'b0;

        // ---- Readback: confirm the data macro kept the preloaded line ----
        $display("INFO  : icache data way0 set0 = %h", u_dut.gen_way[0].u_icache.mem[0]);
        $display("INFO  : dcache data way0 set0 = %h", u_dut.gen_way[0].u_dcache.mem[0]);

        if (error_count == 0) $display("\n[sim_top] ALL CHECKS PASSED");
        else $display("\n[sim_top] %0d CHECK(S) FAILED", error_count);

        $finish;
    end

    // Watchdog: bound the run regardless of the (expected) response-path hang.
    initial begin
        repeat (N_CYCLES) @(posedge clk);
        $display("[sim_top] watchdog timeout after %0d cycles (response path is a TODO)", N_CYCLES);
        $finish;
    end

    // -----------------------------------------------------------------
    // Waveform dump (cwd is sim/, so this writes sim/sim_top.vcd — the
    // path the top-level `make wave` expects).
    // -----------------------------------------------------------------
    initial begin
        $dumpfile("sim_top.vcd");
        $dumpvars(0, sim_top);
    end

endmodule

`resetall
