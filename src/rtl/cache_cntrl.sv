`resetall
`timescale 1ns / 1ps
`default_nettype none

import yarv32_cache_pkg::*;

/**
 * Cache line size: 32 byte
 * I-Cache size: 8 KiB - D-Cache size: 8 KiB = 16 KiB total
 * 8 MiB SDRAM (GW2AR Internal) --> Address is 23 bit wide
 *
 * HASH_INDEX = 0 : classic bit-slice set index
 *                  addr = {tag, set_idx, offset}
 * HASH_INDEX = 1 : hashed set index (cache_set_hash in yarv32_cache_pkg)
 *                  tag stores the full block address (no false hits)
 *
 * Naming: ports use *_i/_o; internals no prefix; flops _q.
 */

module cache_cntrl #(
    // Main memory size
    parameter int MEM_SIZE = 23,  // 2^23 B = 8 MiB
    // Cache line width in bits
    parameter int CL_SIZE = 5,  // Cache line is 2^5 = 32 bytes (DATA_WIDTH)
    // Number of way (caches are set-associative)
    parameter int N_WAY = 2,
    // Cache width in bits (depth = 2^CACHE_SIZE bytes). Both have same size
    parameter int CACHE_SIZE = 13,  // 2^13 = 8 KiB
    // 0 = classic index, 1 = hashed index (see cache_set_hash in package)
    parameter bit HASH_INDEX = 1'b1
) (
    input wire clk_i,
    input wire rstn_i,

    // ICACHE Interface
    input  mem_req_t icache_req_i,
    output mem_rsp_t icache_rsp_o,

    // DCACHE Interface
    input  mem_req_t dcache_req_i,
    output mem_rsp_t dcache_rsp_o,

    // SDRAM Interface (external pins)
    input  wire        sdram_clk_i,    // I_sdram_clk
    input  wire        sdrc_clk_i,     // I_sdrc_clk
    input  wire        sdrc_rst_n_i,   // I_sdrc_rst_n
    output wire        sdram_clk_o,    // O_sdram_clk
    output wire        sdram_cke_o,    // O_sdram_cke
    output wire        sdram_cs_n_o,   // O_sdram_cs_n
    output wire        sdram_cas_n_o,  // O_sdram_cas_n
    output wire        sdram_ras_n_o,  // O_sdram_ras_n
    output wire        sdram_wen_n_o,  // O_sdram_wen_n
    output wire [ 3:0] sdram_dqm_o,    // O_sdram_dqm
    output wire [10:0] sdram_addr_o,   // O_sdram_addr
    output wire [ 1:0] sdram_ba_o,     // O_sdram_ba
    inout  wire [31:0] sdram_dq_io     // IO_sdram_dq
);

    // ===================================================================
    // Local params
    // ===================================================================

    // N_LINES: Number of CACHE lines = 256
    localparam int N_LINES = 1 << (CACHE_SIZE - CL_SIZE);
    localparam int N_SETS = N_LINES / N_WAY;

    // NBIT_OFFSET: 32 B Cache lines --> 5 bit
    localparam int NBIT_OFFSET = CL_SIZE;
    // NBIT_SET_IDX: 128 sets --> 7 bit
    localparam int NBIT_SET_IDX = $clog2(N_SETS);

    // Classic: leftover high bits after {set, offset} + valid + dirty
    // Hashed : full block address (addr without offset) + valid + dirty
    //          because the set index is no longer a bit-slice of the address
    localparam int NBIT_TAG = HASH_INDEX ?
        ((MEM_SIZE - NBIT_OFFSET) + 2) : ((MEM_SIZE - NBIT_SET_IDX - NBIT_OFFSET) + 2);

    // TAG_DATA_W: Round up to the next multiple of 8 (byte-aligned)
    localparam int TAG_DATA_W = ((NBIT_TAG + 7) / 8) * 8;

    // DATA_WIDTH: CL_SIZE Bytes --> 256 bit (32 bytes, 8x32bit words)
    localparam int DATA_WIDTH = 1 << (CL_SIZE + 3);

    // Tag word layout: [NBIT_TAG-1:2] = tag bits, [1] = dirty, [0] = valid
    localparam int TAG_FIELD_W = NBIT_TAG - 2;

    // NBIT_WAY: way-select bits (N_WAY must be a power of 2)
    localparam int NBIT_WAY = $clog2(N_WAY);

    // WAY_ADDR_W: per-way data macro address width. Halves (by NBIT_WAY)
    // vs. a single direct-mapped macro, so N_WAY * 2**WAY_ADDR_W bytes
    // still equals 2**CACHE_SIZE bytes total.
    localparam int WAY_ADDR_W = CACHE_SIZE - NBIT_WAY;

    // TAG_BYTES_W: native_ram treats mem_req_i.addr as a BYTE address and
    // computes word_addr = addr[ADDR_W-1:BYTES_W], dropping the low
    // BYTES_W bits as an intra-word byte select. TAG_DATA_W can be >8
    // bits (STRB_W>1), so set_idx must be left-shifted by this many bits
    // before being placed in itag_req/dtag_req.addr — otherwise the
    // dropped LSB(s) come out of set_idx itself and consecutive sets
    // alias to the same tag word.
    localparam int TAG_BYTES_W = $clog2(TAG_DATA_W / 8);

    // Per-instance protocol types, re-expanded from the package macros at
    // this module's own geometry (the package mem_req_t/cache_req_t are
    // the fixed-width instances of the same macros). way_*_t is one whole
    // cache line wide; tag_*_t is one tag word wide. This keeps the
    // native_ram port widths and the arrays below matched by construction
    // for any CL_SIZE / N_WAY / CACHE_SIZE parameterization.
    `YARV_MEM_TYPES(way_req_t, way_rsp_t, MEM_WIDTH, DATA_WIDTH)
    `YARV_MEM_TYPES(tag_req_t, tag_rsp_t, MEM_WIDTH, TAG_DATA_W)

    // ===================================================================
    // Signal declarations
    // ===================================================================

    mem_req_t bootr_req;  // towards bootrom
    mem_rsp_t bootr_rsp;  // from bootrom

    way_req_t imem_req[N_WAY];  // towards icache ways
    way_rsp_t imem_rsp_d[N_WAY], imem_rsp_q[N_WAY];  // from icache ways
    way_req_t dmem_req[N_WAY];  // towards dcache ways
    way_rsp_t dmem_rsp_d[N_WAY], dmem_rsp_q[N_WAY];  // from dcache ways

    tag_req_t itag_req[N_WAY];  // towards itag ways
    tag_rsp_t itag_rsp[N_WAY];  // from itag ways
    tag_req_t dtag_req[N_WAY];  // towards dtag ways
    tag_rsp_t dtag_rsp[N_WAY];  // from dtag ways

    // SDRAM command interface
    logic sdrc_cmd_en;
    logic [2:0] sdrc_cmd;
    logic sdrc_precharge_ctrl;
    logic sdram_power_down;
    logic sdram_selfrefresh;
    logic [20:0] sdrc_addr;
    logic [3:0] sdrc_dqm;
    logic [31:0] sdrc_data;
    logic [7:0] sdrc_data_len;

    // SDRAM status outputs (internal)
    logic [31:0] sdrc_data_out;
    logic sdrc_init_done;
    logic sdrc_cmd_ack;

    // Per-cache address split. Indexed by CACHE, not by way: set_idx/tag are
    // broadcast to all N_WAY ways of a cache, so there is nothing per-way to
    // compute here. 0 = icache, 1 = dcache.
    localparam int N_CACHE = 2;

    mem_req_t cache_req[N_CACHE];
    assign cache_req[0] = icache_req_i;
    assign cache_req[1] = dcache_req_i;

    logic [N_CACHE-1:0][NBIT_OFFSET-1:0] offset;
    logic [N_CACHE-1:0][NBIT_SET_IDX-1:0] set_idx;
    logic [N_CACHE-1:0][NBIT_TAG-3:0] tag;
    // Word index within a line (32-bit granularity): 2**(CL_SIZE-2) words
    logic [N_CACHE-1:0][$clog2(DATA_WIDTH/32)-1:0] mask;

    // Tag RAM read decode (per way)
    logic [N_WAY-1:0] icache_valid;
    logic [N_WAY-1:0] dcache_valid;
    logic [N_WAY-1:0] icache_dirty;
    logic [N_WAY-1:0] dcache_dirty;
    logic [N_WAY-1:0][TAG_FIELD_W-1:0] icache_tag_stored;
    logic [N_WAY-1:0][TAG_FIELD_W-1:0] dcache_tag_stored;
    logic [N_WAY-1:0] icache_way_hit;
    logic [N_WAY-1:0] dcache_way_hit;

    logic icache_hit;
    logic dcache_hit;


    // ===================================================================
    // Module declarations
    // ===================================================================

    // Bootrom 2 KiB
    native_ram #(
        .ADDR_W    (11),         // 2 KiB
        .DATA_WIDTH(MEM_WIDTH),
        .READ_ONLY (1),
        .INIT_FILE ("")
    ) u_bootrom (
        .clk_i    (clk_i),
        .rstn_i   (rstn_i),
        .mem_req_i(bootr_req),
        .mem_rsp_o(bootr_rsp)
    );

    // ICACHE / DCACHE / I-TAG / D-TAG: N_WAY parallel macros, one per way,
    // looked up in parallel on every request. Data macros are WAY_ADDR_W
    // wide (halved vs. a single direct-mapped macro at N_WAY=2); tag
    // macros stay NBIT_SET_IDX wide (already per-set, unaffected by N_WAY).
    genvar w;
    generate
        for (w = 0; w < N_WAY; w++) begin : gen_way

            native_ram #(
                .ADDR_W    (WAY_ADDR_W),
                .DATA_WIDTH(DATA_WIDTH),
                .REQ_T     (way_req_t),
                .RSP_T     (way_rsp_t),
                .READ_ONLY (0),
                .INIT_FILE ("")
            ) u_icache (
                .clk_i    (clk_i),
                .rstn_i   (rstn_i),
                .mem_req_i(imem_req[w]),
                .mem_rsp_o(imem_rsp_d[w])
            );

            native_ram #(
                .ADDR_W    (WAY_ADDR_W),
                .DATA_WIDTH(DATA_WIDTH),
                .REQ_T     (way_req_t),
                .RSP_T     (way_rsp_t),
                .READ_ONLY (0),
                .INIT_FILE ("")
            ) u_dcache (
                .clk_i    (clk_i),
                .rstn_i   (rstn_i),
                .mem_req_i(dmem_req[w]),
                .mem_rsp_o(dmem_rsp_d[w])
            );

            native_ram #(
                .ADDR_W    (NBIT_SET_IDX),
                .DATA_WIDTH(TAG_DATA_W),
                .REQ_T     (tag_req_t),
                .RSP_T     (tag_rsp_t),
                .READ_ONLY (0),
                .INIT_FILE ("")
            ) u_itag (
                .clk_i    (clk_i),
                .rstn_i   (rstn_i),
                .mem_req_i(itag_req[w]),
                .mem_rsp_o(itag_rsp[w])
            );

            native_ram #(
                .ADDR_W    (NBIT_SET_IDX),
                .DATA_WIDTH(TAG_DATA_W),
                .REQ_T     (tag_req_t),
                .RSP_T     (tag_rsp_t),
                .READ_ONLY (0),
                .INIT_FILE ("")
            ) u_dtag (
                .clk_i    (clk_i),
                .rstn_i   (rstn_i),
                .mem_req_i(dtag_req[w]),
                .mem_rsp_o(dtag_rsp[w])
            );

        end
    endgenerate

    // SDRAM Controller instance
    SDRAM_Controller_HS_Top u_sdram_cntrl (
        .O_sdram_clk          (sdram_clk_o),
        .O_sdram_cke          (sdram_cke_o),
        .O_sdram_cs_n         (sdram_cs_n_o),
        .O_sdram_cas_n        (sdram_cas_n_o),
        .O_sdram_ras_n        (sdram_ras_n_o),
        .O_sdram_wen_n        (sdram_wen_n_o),
        .O_sdram_dqm          (sdram_dqm_o),
        .O_sdram_addr         (sdram_addr_o),
        .O_sdram_ba           (sdram_ba_o),
        .IO_sdram_dq          (sdram_dq_io),
        .I_sdrc_rst_n         (sdrc_rst_n_i),
        .I_sdrc_clk           (sdrc_clk_i),
        .I_sdram_clk          (sdram_clk_i),
        .I_sdrc_cmd_en        (sdrc_cmd_en),
        .I_sdrc_cmd           (sdrc_cmd),
        .I_sdrc_precharge_ctrl(sdrc_precharge_ctrl),
        .I_sdram_power_down   (sdram_power_down),
        .I_sdram_selfrefresh  (sdram_selfrefresh),
        .I_sdrc_addr          (sdrc_addr),
        .I_sdrc_dqm           (sdrc_dqm),
        .I_sdrc_data          (sdrc_data),
        .I_sdrc_data_len      (sdrc_data_len),
        .O_sdrc_data          (sdrc_data_out),
        .O_sdrc_init_done     (sdrc_init_done),
        .O_sdrc_cmd_ack       (sdrc_cmd_ack)
    );


    // ===================================================================
    // TODO: Cache controller logic (hit/miss, refill, write-back, arbitration)
    // ===================================================================
    // Address split + tag RAM read wiring + hit comparison are in place.
    // Refill/write-back FSM still to be added.

    // Address split per cache. generate-if so only one branch is elaborated:
    // HASH_INDEX changes TAG_FIELD_W, and a runtime if would width-mismatch.
    generate
        if (HASH_INDEX) begin : g_hash_index
            always_comb begin
                for (int c = 0; c < N_CACHE; c++) begin
                    offset[c]  = cache_req[c].addr[NBIT_OFFSET-1:0];
                    set_idx[c] = cache_set_hash(cache_req[c].addr[MEM_SIZE-1:0]);
                    tag[c]     = cache_req[c].addr[MEM_SIZE-1:NBIT_OFFSET];
                    mask[c]    = offset[c][NBIT_OFFSET-1:2];
                end
            end
        end else begin : g_classic_index
            always_comb begin
                for (int c = 0; c < N_CACHE; c++) begin
                    offset[c]  = cache_req[c].addr[NBIT_OFFSET-1:0];
                    set_idx[c] = cache_req[c].addr[NBIT_OFFSET+:NBIT_SET_IDX];
                    tag[c]     = cache_req[c].addr[MEM_SIZE-1-:TAG_FIELD_W];
                    mask[c]    = offset[c][NBIT_OFFSET-1:2];
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------
    // Tag RAM read requests (lookup on every incoming request)
    // -------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < N_WAY; i++) begin
            itag_req[i] = '0;
            itag_req[i].valid = icache_req_i.valid;
            itag_req[i].we = 1'b0;  // lookup only, tag write handled by refill FSM
            // set_idx shifted left by TAG_BYTES_W: native_ram drops the low
            // BYTES_W bits of addr as byte-select, not as part of the set
            // index (see TAG_BYTES_W comment above).
            itag_req[i].addr = {
                {(MEM_WIDTH - NBIT_SET_IDX - TAG_BYTES_W) {1'b0}}, set_idx[0], {TAG_BYTES_W{1'b0}}
            };
            itag_req[i].rready = 1'b1;

            dtag_req[i] = '0;
            dtag_req[i].valid = dcache_req_i.valid;
            dtag_req[i].we = 1'b0;
            dtag_req[i].addr = {
                {(MEM_WIDTH - NBIT_SET_IDX - TAG_BYTES_W) {1'b0}}, set_idx[1], {TAG_BYTES_W{1'b0}}
            };
            dtag_req[i].rready = 1'b1;
        end
    end

    // -------------------------------------------------------------
    // Tag compare: hit only once the tag RAM response is valid
    // -------------------------------------------------------------
    always_comb begin
        icache_hit = 1'b0;
        dcache_hit = 1'b0;
        for (int i = 0; i < N_WAY; i++) begin
            icache_valid[i] = itag_rsp[i].rdata[0];
            icache_dirty[i] = itag_rsp[i].rdata[1];
            icache_tag_stored[i] = itag_rsp[i].rdata[2+:TAG_FIELD_W];
            icache_way_hit[i] = itag_rsp[i].rvalid && icache_valid[i] &&
                (icache_tag_stored[i] == tag[0]);
            icache_hit |= icache_way_hit[i];

            dcache_valid[i] = dtag_rsp[i].rdata[0];
            dcache_dirty[i] = dtag_rsp[i].rdata[1];
            dcache_tag_stored[i] = dtag_rsp[i].rdata[2+:TAG_FIELD_W];
            dcache_way_hit[i] = dtag_rsp[i].rvalid && dcache_valid[i] &&
                (dcache_tag_stored[i] == tag[1]);
            dcache_hit |= dcache_way_hit[i];
        end
    end

    // -------------------------------------------------------------
    // ICACHE/DCACHE speculative read
    // If hit, data is already available. If miss, discard read data
    // -------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < N_WAY; i++) begin
            imem_req[i]        = '0;
            imem_req[i].valid  = icache_req_i.valid;
            imem_req[i].we     = 1'b0;  // lookup only, imem write handled by refill FSM
            imem_req[i].wstrb  = '0;  // lookup only, wstrb muxing for hits is TODO
            imem_req[i].addr   = icache_req_i.addr;
            imem_req[i].rready = 1'b1;

            dmem_req[i]        = '0;
            dmem_req[i].valid  = dcache_req_i.valid;
            dmem_req[i].we     = 1'b0;  // lookup only, dmem write handled by refill FSM
            dmem_req[i].wstrb  = '0;  // lookup only, wstrb muxing for hits is TODO
            dmem_req[i].addr   = dcache_req_i.addr;
            dmem_req[i].rready = 1'b1;
        end
    end

    // Registered hit-way / word-select, aligned with imem_rsp_q/dmem_rsp_q
    // (one cycle after the RAM outputs, same stage as the line data).
    logic [N_WAY-1:0] icache_way_hit_q, dcache_way_hit_q;
    logic [$clog2(DATA_WIDTH/32)-1:0] icache_word_sel_q, dcache_word_sel_q;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            icache_way_hit_q  <= '0;
            dcache_way_hit_q  <= '0;
            icache_word_sel_q <= '0;
            dcache_word_sel_q <= '0;
        end else begin
            imem_rsp_q        <= imem_rsp_d;
            dmem_rsp_q        <= dmem_rsp_d;
            icache_way_hit_q  <= icache_way_hit;
            dcache_way_hit_q  <= dcache_way_hit;
            icache_word_sel_q <= mask[0];
            dcache_word_sel_q <= mask[1];
        end
    end

    // ===================================================================
    // Miss-handling FSM
    // ===================================================================
    // Hits never enter this FSM (they're served combinationally above).
    // Only a miss triggers arbitration for the shared SDRAM controller.
    // NOTE: this is a skeleton. Items marked TODO need to be resolved
    // against the Gowin SDRAM HS IP command encoding / address mapping
    // and the way-storage scheme (N_WAY=2 needs per-way tag/data arrays,
    // not modeled by the single native_ram instances above).

    localparam int BURST_LEN = DATA_WIDTH / 32;  // 32-bit SDRAM data bus

    typedef enum logic [2:0] {
        S_IDLE,
        S_ARBITRATE,
        S_WB_REQ,       // writeback burst; skipped if victim not dirty
        S_WB_WAIT,
        S_REFILL_REQ,
        S_REFILL_WAIT,
        S_UPDATE_TAG
    } fsm_state_e;

    fsm_state_e state_q, state_d;

    logic req_sel_q, req_sel_d;  // 0 = icache, 1 = dcache
    logic [3:0] burst_cnt_q, burst_cnt_d;  // 0 .. BURST_LEN-1
    logic [DATA_WIDTH-1:0] line_buf_q, line_buf_d;  // staged/assembled cache line
    logic victim_dirty_q;  // TODO: latch from way-select logic
    logic [MEM_WIDTH-1:0] miss_addr_q, miss_addr_d;

    logic miss_pending;
    // itag_rsp/dtag_rsp[*].rvalid are identical across ways (same broadcast
    // lookup, same native_ram latency), so way 0 is a valid representative.
    assign
        miss_pending = (itag_rsp[0].rvalid && !icache_hit) || (dtag_rsp[0].rvalid && !dcache_hit);

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            state_q     <= S_IDLE;
            req_sel_q   <= 1'b0;
            burst_cnt_q <= '0;
            line_buf_q  <= '0;
            miss_addr_q <= '0;
        end else begin
            state_q     <= state_d;
            req_sel_q   <= req_sel_d;
            burst_cnt_q <= burst_cnt_d;
            line_buf_q  <= line_buf_d;
            miss_addr_q <= miss_addr_d;
        end
    end

    always_comb begin
        // defaults: hold state / datapath
        state_d             = state_q;
        req_sel_d           = req_sel_q;
        burst_cnt_d         = burst_cnt_q;
        line_buf_d          = line_buf_q;
        miss_addr_d         = miss_addr_q;

        sdrc_cmd_en         = 1'b0;
        sdrc_cmd            = 3'b000;  // TODO: confirm encoding vs SDRAM HS IP doc
        sdrc_addr           = '0;
        sdrc_data           = '0;
        sdrc_data_len       = '0;
        sdrc_precharge_ctrl = 1'b0;
        sdram_power_down    = 1'b0;
        sdram_selfrefresh   = 1'b0;

        unique case (state_q)

            S_IDLE: begin
                burst_cnt_d = '0;
                if (miss_pending) begin
                    // Fixed priority: dcache wins ties (avoids stalling stores)
                    req_sel_d   = dtag_rsp[0].rvalid && !dcache_hit;
                    miss_addr_d = req_sel_d ? dcache_req_i.addr : icache_req_i.addr;
                    state_d     = S_ARBITRATE;
                end
            end

            S_ARBITRATE: begin
                // TODO: victim way select (round-robin/LRU per set) +
                // latch victim_dirty from the selected way's tag entry.
                state_d = victim_dirty_q ? S_WB_REQ : S_REFILL_REQ;
            end

            S_WB_REQ: begin
                sdrc_cmd_en   = 1'b1;
                sdrc_cmd      = 3'b001;  // TODO: write command encoding
                sdrc_addr     = miss_addr_q[MEM_SIZE-1-:21];  // TODO: bank/row/col mapping
                sdrc_data     = line_buf_q[burst_cnt_q*32+:32];
                sdrc_data_len = BURST_LEN[7:0];
                if (sdrc_cmd_ack) begin
                    // Zero-extend so the 4-bit counter compares width-clean
                    // against the 32-bit int localparam.
                    if ({28'd0, burst_cnt_q} == BURST_LEN - 1) state_d = S_WB_WAIT;
                    else burst_cnt_d = burst_cnt_q + 1'b1;
                end
            end

            S_WB_WAIT: begin
                // TODO: real completion condition (tWR / cmd_ack sequencing),
                // sdrc_init_done is a placeholder only.
                if (sdrc_init_done) begin
                    burst_cnt_d = '0;
                    state_d     = S_REFILL_REQ;
                end
            end

            S_REFILL_REQ: begin
                sdrc_cmd_en   = 1'b1;
                sdrc_cmd      = 3'b010;  // TODO: read command encoding
                sdrc_addr     = miss_addr_q[MEM_SIZE-1-:21];
                sdrc_data_len = BURST_LEN[7:0];
                if (sdrc_cmd_ack) state_d = S_REFILL_WAIT;
            end

            S_REFILL_WAIT: begin
                // TODO: qualify with the controller's per-word data-valid
                // strobe instead of assuming one word per cycle.
                line_buf_d[burst_cnt_q*32+:32] = sdrc_data_out;
                if ({28'd0, burst_cnt_q} == BURST_LEN - 1) state_d = S_UPDATE_TAG;
                else burst_cnt_d = burst_cnt_q + 1'b1;
            end

            S_UPDATE_TAG: begin
                // TODO: drive itag_req/dtag_req (we=1, addr=set_idx<<TAG_BYTES_W,
                // wdata={tag,dirty=0,valid=1}) and imem_req/dmem_req to commit
                // line_buf_q, then unstall the requester (icache_rsp_o/dcache_rsp_o).
                // Tag field width is TAG_FIELD_W (11 classic / 18 hashed).
                state_d = S_IDLE;
            end

            default: state_d = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------
    // CPU-facing response: hit-way line mux + 32-bit word select
    // -------------------------------------------------------------
    // imem_rsp_q/dmem_rsp_q each hold one full 256-bit line per way; the
    // winning way is the one whose tag hit (registered, same pipeline stage
    // as the data). The requested 32-bit word inside that line is selected
    // by the intra-line word offset (mask, i.e. addr[NBIT_OFFSET-1:2]).
    // TODO: rdata is MEM_WIDTH=64 bits but the select granularity is 32 bits;
    // 64-bit CPU accesses need a doubleword select (addr[NBIT_OFFSET-1:3]).
    logic [DATA_WIDTH-1:0] icache_line, dcache_line;

    always_comb begin
        icache_line = '0;
        dcache_line = '0;
        for (int i = 0; i < N_WAY; i++) begin
            if (icache_way_hit_q[i]) icache_line = imem_rsp_q[i].rdata;
            if (dcache_way_hit_q[i]) dcache_line = dmem_rsp_q[i].rdata;
        end
    end

    // wready: cache accepts a new CPU request only while the miss FSM is idle
    // (hit path needs no FSM cycles; a miss stalls the requester).
    assign icache_rsp_o.wready = (state_q == S_IDLE);
    assign icache_rsp_o.rvalid = imem_rsp_q[0].rvalid && (|icache_way_hit_q);
    assign icache_rsp_o.rdata  = icache_line[icache_word_sel_q*64+:64];
    assign icache_rsp_o.bvalid = 1'b0;  // posted stores, no B channel

    assign dcache_rsp_o.wready = (state_q == S_IDLE);
    assign dcache_rsp_o.rvalid = dmem_rsp_q[0].rvalid && (|dcache_way_hit_q);
    assign dcache_rsp_o.rdata  = icache_line[dcache_word_sel_q*64+:64];
    assign dcache_rsp_o.bvalid = 1'b0;  // posted stores, no B channel

`ifdef VERILATOR
    logic                  icache_req_valid;
    logic                  icache_req_we;
    logic [ MEM_WIDTH-1:0] icache_req_addr;
    logic [ MEM_WIDTH-1:0] icache_req_wdata;
    logic [STRB_WIDTH-1:0] icache_req_wstrb;
    logic                  icache_req_rready;
    assign icache_req_valid  = icache_req_i.valid;
    assign icache_req_we     = icache_req_i.we;
    assign icache_req_addr   = icache_req_i.addr;
    assign icache_req_wdata  = icache_req_i.wdata;
    assign icache_req_wstrb  = icache_req_i.wstrb;
    assign icache_req_rready = icache_req_i.rready;

    logic                    itag0_req_valid;
    logic                    itag0_req_we;
    logic [   MEM_WIDTH-1:0] itag0_req_addr;
    logic [  TAG_DATA_W-1:0] itag0_req_wdata;
    logic [TAG_DATA_W/8-1:0] itag0_req_wstrb;
    logic                    itag0_req_rready;
    assign itag0_req_valid  = itag_req[0].valid;
    assign itag0_req_we     = itag_req[0].we;
    assign itag0_req_addr   = itag_req[0].addr;
    assign itag0_req_wdata  = itag_req[0].wdata;
    assign itag0_req_wstrb  = itag_req[0].wstrb;
    assign itag0_req_rready = itag_req[0].rready;

    logic                  itag0_rsp_wready;
    logic                  itag0_rsp_rvalid;
    logic [TAG_DATA_W-1:0] itag0_rsp_rdata;
    logic                  itag0_rsp_bvalid;
    assign itag0_rsp_wready = itag_rsp[0].wready;
    assign itag0_rsp_rvalid = itag_rsp[0].rvalid;
    assign itag0_rsp_rdata  = itag_rsp[0].rdata;
    assign itag0_rsp_bvalid = itag_rsp[0].bvalid;

    logic                  imem0_rsp_q_wready;
    logic                  imem0_rsp_q_rvalid;
    logic [DATA_WIDTH-1:0] imem0_rsp_q_rdata;
    logic                  imem0_rsp_q_bvalid;
    assign imem0_rsp_q_wready = imem_rsp_q[0].wready;
    assign imem0_rsp_q_rvalid = imem_rsp_q[0].rvalid;
    assign imem0_rsp_q_rdata  = imem_rsp_q[0].rdata;
    assign imem0_rsp_q_bvalid = imem_rsp_q[0].bvalid;

    logic        icache0_rsp_o_wready;
    logic        icache0_rsp_o_rvalid;
    logic [63:0] icache0_rsp_o_rdata;
    logic        icache0_rsp_o_bvalid;
    assign icache0_rsp_o_wready = icache_rsp_o.wready;
    assign icache0_rsp_o_rvalid = icache_rsp_o.rvalid;
    assign icache0_rsp_o_rdata  = icache_rsp_o.rdata;
    assign icache0_rsp_o_bvalid = icache_rsp_o.bvalid;

`endif

endmodule

`resetall
