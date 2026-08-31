`resetall
`timescale 1ns / 1ps
`default_nettype none

import yarv32_cache_pkg::*;

/**
 * Verilator testbench / top for the yarv32 cache subsystem.
 *
 * HASH_INDEX is an int parameter (so verilator -GHASH_INDEX=1 is width-clean)
 * forwarded to cache_cntrl:
 *   HASH_INDEX=0 : classic bit-slice set, 11-bit tag, 16-bit tag word
 *   HASH_INDEX=1 : cache_set_hash(addr[22:0]), 18-bit tag, 24-bit tag word
 *
 *   verilator ... -GHASH_INDEX=1 --top-module sim_top ...
 *
 * Data macros are still addressed by the raw CPU address, so the data-word
 * index is always addr[11:5]. Tag macros drop TAG_BYTES_W LSBs of the set
 * (native_ram byte-address decode).
 */

module sim_top #(
    parameter int HASH_INDEX = 0
);

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

    cache_cntrl #(
        .HASH_INDEX(HASH_INDEX != 0)
    ) u_dut (
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

    string iinit, dinit;
    initial begin
        if ($value$plusargs("IINIT=%s", iinit))
            $display("[sim_top] +IINIT=%0s (preload is hierarchical; ignored)", iinit);
        if ($value$plusargs("DINIT=%s", dinit))
            $display("[sim_top] +DINIT=%0s (preload is hierarchical; ignored)", dinit);
    end

    localparam int MEM_SIZE = 23;
    localparam int NBIT_OFFSET = 5;
    localparam int NBIT_SET_IDX = 7;
    localparam int TAG_FIELD_W = (HASH_INDEX != 0) ?
        (MEM_SIZE - NBIT_OFFSET) : (MEM_SIZE - NBIT_SET_IDX - NBIT_OFFSET);
    localparam int NBIT_TAG = TAG_FIELD_W + 2;
    localparam int TAG_DATA_W = ((NBIT_TAG + 7) / 8) * 8;
    localparam int TAG_BYTES_W = $clog2(TAG_DATA_W / 8);
    localparam int TAG_WORD_AW = NBIT_SET_IDX - TAG_BYTES_W;

    localparam logic [22:0] ADDR_I_HIT = 23'h3C_D1A5;
    localparam logic [22:0] ADDR_I_MISS = 23'h00_2000;
    localparam logic [22:0] ADDR_D_HIT = 23'h00_0000;

    localparam logic [255:0] LINE_PATTERN =
        256'h8778_7667_6556_5445_4334_3223_2112_1001_DDEE_DDCC_BBAA_9988_7766_5544_3322_1100;

    localparam int DATA_WORD_I_HIT = int'(ADDR_I_HIT[NBIT_OFFSET+:NBIT_SET_IDX]);
    localparam int DATA_WORD_D_HIT = int'(ADDR_D_HIT[NBIT_OFFSET+:NBIT_SET_IDX]);

    // Both branches of each function are width-matched so Verilator does not
    // WIDTHTRUNC the unused HASH_INDEX path.
    function automatic logic [NBIT_SET_IDX-1:0] set_of(input logic [22:0] addr);
        if (HASH_INDEX != 0) set_of = cache_set_hash(addr);
        else set_of = addr[NBIT_OFFSET+:NBIT_SET_IDX];
    endfunction

    function automatic logic [17:0] tag18_of(input logic [22:0] addr);
        if (HASH_INDEX != 0) tag18_of = addr[MEM_SIZE-1:NBIT_OFFSET];
        else tag18_of = {7'b0, addr[MEM_SIZE-1:NBIT_OFFSET+NBIT_SET_IDX]};
    endfunction

    function automatic logic [TAG_DATA_W-1:0] tag_word(input logic [22:0] addr);
        logic [TAG_FIELD_W-1:0] t;
        t        = tag18_of(addr) [TAG_FIELD_W-1:0];
        tag_word = {{(TAG_DATA_W - TAG_FIELD_W - 2) {1'b0}}, t, 1'b0, 1'b1};
    endfunction

    initial begin
        $display("[sim_top] HASH_INDEX=%0d  TAG_FIELD_W=%0d  TAG_DATA_W=%0d  TAG_WORD_AW=%0d",
                 HASH_INDEX, TAG_FIELD_W, TAG_DATA_W, TAG_WORD_AW);
        $display("[sim_top] I-hit  addr=0x%0h set=%0d tag=0x%0h tagword=0x%0h data_word=%0d",
                 ADDR_I_HIT, set_of(ADDR_I_HIT), tag18_of(ADDR_I_HIT) [TAG_FIELD_W-1:0], tag_word(
                 ADDR_I_HIT), DATA_WORD_I_HIT);
        $display("[sim_top] D-hit  addr=0x%0h set=%0d tag=0x%0h tagword=0x%0h data_word=%0d",
                 ADDR_D_HIT, set_of(ADDR_D_HIT), tag18_of(ADDR_D_HIT) [TAG_FIELD_W-1:0], tag_word(
                 ADDR_D_HIT), DATA_WORD_D_HIT);
        $display("[sim_top] I-miss addr=0x%0h set=%0d", ADDR_I_MISS, set_of(ADDR_I_MISS));
    end

    initial begin
        u_dut.gen_way[0].u_itag.mem[set_of(ADDR_I_HIT) [TAG_WORD_AW-1:0]] = tag_word(ADDR_I_HIT);
        u_dut.gen_way[1].u_itag.mem[set_of(ADDR_I_HIT) [TAG_WORD_AW-1:0]] = {TAG_DATA_W{1'b0}};
        u_dut.gen_way[0].u_icache.mem[DATA_WORD_I_HIT]                    = LINE_PATTERN;

        u_dut.gen_way[0].u_dtag.mem[set_of(ADDR_D_HIT) [TAG_WORD_AW-1:0]] = tag_word(ADDR_D_HIT);
        u_dut.gen_way[1].u_dtag.mem[set_of(ADDR_D_HIT) [TAG_WORD_AW-1:0]] = {TAG_DATA_W{1'b0}};
        u_dut.gen_way[0].u_dcache.mem[DATA_WORD_D_HIT]                    = LINE_PATTERN;
    end

    localparam int N_CYCLES = 300;
    integer error_count;
    logic   hit_sample;

    initial begin
        error_count = 0;
        rstn        = 1'b0;
        icache_req  = '0;
        dcache_req  = '0;

        repeat (2) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);

        icache_req.valid  = 1'b1;
        icache_req.we     = 1'b0;
        icache_req.addr   = {{(64 - 23) {1'b0}}, ADDR_I_HIT};
        icache_req.rready = 1'b1;

        repeat (5) @(posedge clk);
        hit_sample = u_dut.icache_hit;

        if (hit_sample !== 1'b1) begin
            error_count = error_count + 1;
            $display("FAIL  A: icache_hit at 0x%0h expected 1, got %0b (set=%0d HASH_INDEX=%0d)",
                     ADDR_I_HIT, hit_sample, set_of(ADDR_I_HIT), HASH_INDEX);
        end else begin
            $display("PASS  A: icache HIT at 0x%0h (way_hit=%b set=%0d HASH_INDEX=%0d)",
                     ADDR_I_HIT, u_dut.icache_way_hit, set_of(ADDR_I_HIT), HASH_INDEX);
        end

        icache_req.addr = {{(64 - 23) {1'b0}}, ADDR_I_MISS};
        repeat (5) @(posedge clk);
        hit_sample = u_dut.icache_hit;
        if (hit_sample !== 1'b0) begin
            error_count = error_count + 1;
            $display("FAIL  B: icache_hit at 0x%0h expected 0, got %0b", ADDR_I_MISS, hit_sample);
        end else if (u_dut.state_q == 3'd0) begin
            error_count = error_count + 1;
            $display("FAIL  B: miss did not start the FSM (still S_IDLE)");
        end else begin
            $display("PASS  B: icache MISS at 0x%0h (hit=0, FSM state=%0s)", ADDR_I_MISS,
                     u_dut.state_q.name());
        end

        icache_req.valid = 1'b0;
        repeat (2) @(posedge clk);

        dcache_req.valid  = 1'b1;
        dcache_req.we     = 1'b0;
        dcache_req.addr   = {{(64 - 23) {1'b0}}, ADDR_D_HIT};
        dcache_req.rready = 1'b1;
        repeat (5) @(posedge clk);
        hit_sample = u_dut.dcache_hit;
        if (hit_sample !== 1'b1) begin
            error_count = error_count + 1;
            $display("FAIL  C: dcache_hit at 0x%0h expected 1, got %0b (set=%0d)", ADDR_D_HIT,
                     hit_sample, set_of(ADDR_D_HIT));
        end else begin
            $display("PASS  C: dcache HIT at 0x%0h (way_hit=%b set=%0d)", ADDR_D_HIT,
                     u_dut.dcache_way_hit, set_of(ADDR_D_HIT));
        end
        dcache_req.valid = 1'b0;

        $display("INFO  : icache data way0 word%0d = %h", DATA_WORD_I_HIT,
                 u_dut.gen_way[0].u_icache.mem[DATA_WORD_I_HIT]);
        $display("INFO  : dcache data way0 word%0d = %h", DATA_WORD_D_HIT,
                 u_dut.gen_way[0].u_dcache.mem[DATA_WORD_D_HIT]);

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
