`resetall
`timescale 1ns / 1ps
`default_nettype none

import yarv32_cache_pkg::*;

/**
 * Cache line size: 32 byte
 * I-Cache size: 8 KiB - D-Cache size: 8 KiB = 16 KiB total
 * 8 MiB SDRAM (GW2AR Internal) --> Address is 23 bit wide
 * addr = {tag, set_idx, offset} (classic bit-slice set index)
 * CPU access width is 64 bit (doubleword select, addr[NBIT_OFFSET-1:3])
 * I-mem port: read-only, up to 2 outstanding reads (fetch instruction buffer)
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
    parameter int CACHE_SIZE = 13  // 2^13 = 8 KiB
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

    // {tag, set, offset} split + valid + dirty
    localparam int NBIT_TAG = MEM_SIZE - NBIT_SET_IDX - NBIT_OFFSET + 2;

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

    // Tag macro address width: NBIT_SET_IDX word-select bits + TAG_BYTES_W
    // intra-word byte-select bits, so the macro stores one tag word per set
    // (native_ram decodes word_addr = addr[TAG_ADDR_W-1:TAG_BYTES_W] =
    // set_idx). An ADDR_W of NBIT_SET_IDX alone would drop the byte-select
    // bits out of set_idx and alias sets 2**TAG_BYTES_W apart onto one tag
    // word (false hits / clobbered tags).
    localparam int TAG_ADDR_W = NBIT_SET_IDX + TAG_BYTES_W;

    // Per-instance protocol types, re-expanded from the package macros at
    // this module's own geometry (the package mem_req_t/cache_req_t are
    // the fixed-width instances of the same macros). way_*_t is one whole
    // cache line wide; tag_*_t is one tag word wide. This keeps the
    // native_ram port widths and the arrays below matched by construction
    // for any CL_SIZE / N_WAY / CACHE_SIZE parameterization.
    `YARV_MEM_TYPES(way_req_t, way_rsp_t, MEM_WIDTH, DATA_WIDTH)
    `YARV_MEM_TYPES(tag_req_t, tag_rsp_t, MEM_WIDTH, TAG_DATA_W)

`ifdef VERILATOR
    // Elaboration-time geometry check: the tag macros must have one word
    // per set (see TAG_ADDR_W above).
    initial begin
        assert ((1 << (TAG_ADDR_W - TAG_BYTES_W)) >= N_SETS)
        else
            $fatal(
                1,
                "tag macro word depth (%0d) < N_SETS (%0d)",
                1 << (TAG_ADDR_W - TAG_BYTES_W),
                N_SETS
            );
    end
`endif

    // ===================================================================
    // Signal declarations
    // ===================================================================

    mem_req_t bootr_req;  // towards bootrom
    mem_rsp_t bootr_rsp;  // from bootrom

    way_req_t imem_req[N_WAY];  // towards icache ways
    way_rsp_t imem_rsp_d[N_WAY];  // from icache ways
    way_req_t dmem_req[N_WAY];  // towards dcache ways
    way_rsp_t dmem_rsp_d[N_WAY];  // from dcache ways

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

    // Per-cache request skid, slot-indexed (freed slots are reused as a
    // free list; at most one slot is ever un-launched, so launch order =
    // accept order and responses stay in order). A CPU request is accepted
    // into a free slot at the launch handshake; the address split, the
    // tag/data macro lookups, and the tag compare all run off the
    // REGISTERED request, so the 1-cycle-old tag RAM output is compared
    // against the address that launched the lookup — no stale-tag race when
    // the CPU changes the address after accept. Indexed by CACHE, not by
    // way: set_idx/tag are broadcast to all N_WAY ways of a cache.
    // 0 = icache, 1 = dcache.
    localparam int N_CACHE = 2;
    localparam int N_SLOT = 2;

    // Outstanding-request limit per cache: 2 for the read-only I-port (the
    // fetch unit's 2 in-flight reads), 1 for the D-port (single-outstanding).
    localparam int SKID_DEPTH[N_CACHE] = '{2, 1};

    mem_req_t skid_q[N_CACHE][N_SLOT];  // accepted requests (skid slots)
    logic skid_valid_q[N_CACHE][N_SLOT];  // slot occupied
    logic slot_lookup_q[N_CACHE][N_SLOT];  // lookup launched for this slot
    logic slot_rsp_q[N_CACHE][N_SLOT];  // this slot's tag answer arrives now
    logic miss_seen_q[N_CACHE][N_SLOT];  // slot missed; waiting for FSM pickup
    logic [N_SLOT-1:0] slot_miss_q[N_CACHE];  // slot's miss taken by the FSM:
    // blocks younger queue entries until the miss completes (TODO Phase 4)

    // Response queue (per cache): captured hit data, delivered to the CPU in
    // accept order. rvalid is a LEVEL held until rready pops the head —
    // protocol compliance, not a one-cycle lookup pulse.
    logic [MEM_WIDTH-1:0] rq_q[N_CACHE][N_SLOT];  // rq_q[c][0] is the head
    logic rq_blk_q[N_CACHE][N_SLOT];  // entry waits behind an older miss
    logic [1:0] rq_cnt_q[N_CACHE];  // entries in the queue (0..2)

    // Lookup compare context, registered at lookup launch. With back-to-back
    // I-port lookups the address split has already moved on to the next slot
    // when a tag answer arrives, so the compare runs against this registered
    // copy, not the live split.
    logic [N_CACHE-1:0][TAG_FIELD_W-1:0] cmp_tag_q;
    logic [N_CACHE-1:0][$clog2(DATA_WIDTH/64)-1:0] cmp_dw_sel_q;
    logic [N_CACHE-1:0] cmp_we_q;

    // Slot selection (per cache, always_comb — Verilator's V3Delayed chokes
    // on multiple calls of the same automatic function from a clocked
    // block). At most one slot is ever un-launched, so "first matching
    // slot" is unambiguous. The 0 defaults are unreachable whenever the
    // corresponding strobe (accept / lookup_go / rsp pulse / fsm latch) is
    // asserted.
    int slot_free[N_CACHE];  // first free slot (skid full only if !wready)
    int slot_lookup_sel[N_CACHE];  // slot to launch the lookup for
    int slot_rsp_sel[N_CACHE];  // slot the tag answer belongs to
    int slot_miss_sel[N_CACHE];  // oldest slot the FSM will pick up
    logic slot_miss_wait[N_CACHE];  // a slot awaits FSM pickup
    int slot_outstanding[N_CACHE];  // occupied slots + queue entries

    always_comb begin
        for (int c = 0; c < N_CACHE; c++) begin
            if (!skid_valid_q[c][0]) slot_free[c] = 0;
            else if (!skid_valid_q[c][1]) slot_free[c] = 1;
            else slot_free[c] = 0;  // full: unreachable while wready=1

            if (skid_valid_q[c][0] && !slot_lookup_q[c][0]) slot_lookup_sel[c] = 0;
            else if (skid_valid_q[c][1] && !slot_lookup_q[c][1]) slot_lookup_sel[c] = 1;
            else slot_lookup_sel[c] = 0;  // no pending lookup; content unused

            if (slot_rsp_q[c][0]) slot_rsp_sel[c] = 0;
            else if (slot_rsp_q[c][1]) slot_rsp_sel[c] = 1;
            else slot_rsp_sel[c] = 0;

            if (skid_valid_q[c][0] && miss_seen_q[c][0]) slot_miss_sel[c] = 0;
            else if (skid_valid_q[c][1] && miss_seen_q[c][1]) slot_miss_sel[c] = 1;
            else slot_miss_sel[c] = 0;

            slot_miss_wait[c] = (skid_valid_q[c][0] && miss_seen_q[c][0]) ||
                (skid_valid_q[c][1] && miss_seen_q[c][1]);

            // Outstanding units: occupied skid slots plus unconsumed queue
            // entries. Every accepted read stays exactly one unit until the
            // CPU consumes it, so the queue can never overflow SKID_DEPTH.
            slot_outstanding[c] = (skid_valid_q[c][0] ? 1 : 0) + (skid_valid_q[c][1] ? 1 : 0) +
                32'(rq_cnt_q[c]);
        end
    end

    // The address split runs off the skid slot being launched (see skid_q).
    mem_req_t cache_req[N_CACHE];

    always_comb begin
        for (int c = 0; c < N_CACHE; c++) cache_req[c] = skid_q[c][slot_lookup_sel[c]];
    end

    // Lookup issue: exactly one tag+data macro lookup per accepted request
    // (slot_lookup_q gates relaunch while the CPU holds rready=1).
    logic cache_lookup_go[N_CACHE];

    always_comb begin
        for (int c = 0; c < N_CACHE; c++) begin
            cache_lookup_go[c] = (skid_valid_q[c][0] && !slot_lookup_q[c][0]) ||
                (skid_valid_q[c][1] && !slot_lookup_q[c][1]);
        end
    end

    // One response pulse per lookup: itag_rsp/dtag_rsp rvalid are identical
    // across ways (same broadcast lookup, same native_ram latency), so way 0
    // is a valid representative.
    logic cache_rsp_pulse[N_CACHE];
    logic cache_hit_pulse[N_CACHE];
    assign cache_rsp_pulse[0] = itag_rsp[0].rvalid;
    assign cache_rsp_pulse[1] = dtag_rsp[0].rvalid;
    assign cache_hit_pulse[0] = cache_rsp_pulse[0] && icache_hit;
    assign cache_hit_pulse[1] = cache_rsp_pulse[1] && dcache_hit;

    logic [N_CACHE-1:0][NBIT_OFFSET-1:0] offset;
    logic [N_CACHE-1:0][NBIT_SET_IDX-1:0] set_idx;
    logic [N_CACHE-1:0][NBIT_TAG-3:0] tag;
    // Doubleword index within a line (64-bit granularity):
    // 2**(CL_SIZE-3) doublewords, selected by addr[NBIT_OFFSET-1:3]
    logic [N_CACHE-1:0][$clog2(DATA_WIDTH/64)-1:0] dw_sel;

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
    // macros are TAG_ADDR_W wide (one tag word per set, see TAG_ADDR_W).
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
                .ADDR_W    (TAG_ADDR_W),
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
                .ADDR_W    (TAG_ADDR_W),
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

    // Address split per cache (classic bit-slice): addr = {tag, set, offset}.
    always_comb begin
        for (int c = 0; c < N_CACHE; c++) begin
            offset[c]  = cache_req[c].addr[NBIT_OFFSET-1:0];
            set_idx[c] = cache_req[c].addr[NBIT_OFFSET+:NBIT_SET_IDX];
            tag[c]     = cache_req[c].addr[MEM_SIZE-1-:TAG_FIELD_W];
            dw_sel[c]  = offset[c][NBIT_OFFSET-1:3];
        end
    end

    // -------------------------------------------------------------
    // Tag RAM read requests (one lookup per accepted request, from req_q)
    // -------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < N_WAY; i++) begin
            itag_req[i] = '0;
            itag_req[i].valid = cache_lookup_go[0];
            itag_req[i].we = 1'b0;  // lookup only, tag write handled by refill FSM
            // set_idx shifted left by TAG_BYTES_W: native_ram drops the low
            // BYTES_W bits of addr as byte-select, not as part of the set
            // index (see TAG_BYTES_W comment above).
            itag_req[i].addr = {
                {(MEM_WIDTH - NBIT_SET_IDX - TAG_BYTES_W) {1'b0}}, set_idx[0], {TAG_BYTES_W{1'b0}}
            };
            itag_req[i].rready = 1'b1;

            dtag_req[i] = '0;
            dtag_req[i].valid = cache_lookup_go[1];
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
                (icache_tag_stored[i] == cmp_tag_q[0]);
            icache_hit |= icache_way_hit[i];

            dcache_valid[i] = dtag_rsp[i].rdata[0];
            dcache_dirty[i] = dtag_rsp[i].rdata[1];
            dcache_tag_stored[i] = dtag_rsp[i].rdata[2+:TAG_FIELD_W];
            dcache_way_hit[i] = dtag_rsp[i].rvalid && dcache_valid[i] &&
                (dcache_tag_stored[i] == cmp_tag_q[1]);
            dcache_hit |= dcache_way_hit[i];
        end
    end

    // -------------------------------------------------------------
    // ICACHE/DCACHE speculative read, launched with the tag lookup
    // (one per accepted request). If hit, data is already available in the
    // imem_rsp_q/dmem_rsp_q stage one cycle later. If miss, discard read
    // data.
    // -------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < N_WAY; i++) begin
            imem_req[i]        = '0;
            imem_req[i].valid  = cache_lookup_go[0];
            imem_req[i].we     = 1'b0;  // lookup only, imem write handled by refill FSM
            imem_req[i].wstrb  = '0;  // lookup only, wstrb muxing for hits is TODO
            imem_req[i].addr   = cache_req[0].addr;
            imem_req[i].rready = 1'b1;

            dmem_req[i]        = '0;
            dmem_req[i].valid  = cache_lookup_go[1];
            dmem_req[i].we     = 1'b0;  // lookup only, dmem write handled by refill FSM
            dmem_req[i].wstrb  = '0;  // lookup only, wstrb muxing for hits is TODO
            dmem_req[i].addr   = cache_req[1].addr;
            dmem_req[i].rready = 1'b1;
        end
    end

    // -------------------------------------------------------------
    // Hit-way line mux over the RAW data-macro outputs. A response is
    // captured into the queue at the tag-answer cycle (the same cycle the
    // lookup pulse fires), one stage earlier than the old imem_rsp_q path.
    // -------------------------------------------------------------
    logic [DATA_WIDTH-1:0] icache_line, dcache_line;

    always_comb begin
        icache_line = '0;
        dcache_line = '0;
        for (int i = 0; i < N_WAY; i++) begin
            if (icache_way_hit[i]) icache_line = imem_rsp_d[i].rdata;
            if (dcache_way_hit[i]) dcache_line = dmem_rsp_d[i].rdata;
        end
    end

    // 64-bit doubleword selected out of the hit line (cmp_dw_sel_q is the
    // launch-registered copy of addr[NBIT_OFFSET-1:3]).
    logic [MEM_WIDTH-1:0] icache_push_data, dcache_push_data;
    assign icache_push_data = icache_line[cmp_dw_sel_q[0]*64+:64];
    assign dcache_push_data = dcache_line[cmp_dw_sel_q[1]*64+:64];

    // -------------------------------------------------------------
    // Skid + response queue state (per cache):
    //   accept    : raw CPU request latched into the first free slot
    //   lookup_go : launches the one tag+data lookup for that slot and
    //               registers the compare context (cmp_tag_q/cmp_dw_sel_q/
    //               cmp_we_q) off the launching slot's split
    //   rsp pulse : the lookup's tag answer. A hit frees the slot; a load
    //               hit also pushes {rdata, blk} onto the response queue.
    //               A store hit is a posted store — no response (the
    //               data-macro write is TODO Phase 4). A miss flags
    //               miss_seen_q for the FSM and keeps the slot occupied so
    //               no younger response can pass an older miss.
    //   pop       : the CPU consumed the queue head (rready)
    //   fsm_latch : the miss FSM took the slot over: miss_seen_q clears,
    //               slot_miss_q sets. slot_miss_q stays set (blocking
    //               younger entries) until the miss completes and the
    //               requester is unstalled (TODO Phase 4); the slot counts
    //               as outstanding the whole time, so wready stays low on
    //               the single-outstanding D-port.
    // -------------------------------------------------------------
    logic cache_accept[N_CACHE];
    assign cache_accept[0] = icache_req_i.valid && icache_rsp_o.wready;
    assign cache_accept[1] = dcache_req_i.valid && dcache_rsp_o.wready;

    // CPU consumed the queue head.
    logic cache_pop[N_CACHE];
    assign cache_pop[0] = icache_req_i.rready && icache_rsp_o.rvalid;
    assign cache_pop[1] = dcache_req_i.rready && dcache_rsp_o.rvalid;

    // Queue push: the tag answer was a load hit.
    logic cache_push[N_CACHE];
    assign cache_push[0] = cache_rsp_pulse[0] && cache_hit_pulse[0] && !cmp_we_q[0];
    assign cache_push[1] = cache_rsp_pulse[1] && cache_hit_pulse[1] && !cmp_we_q[1];

    logic [MEM_WIDTH-1:0] cache_push_data[N_CACHE];
    assign cache_push_data[0] = icache_push_data;
    assign cache_push_data[1] = dcache_push_data;

    // An unresolved miss (pending pickup or owned by the FSM) older than
    // the entry being pushed blocks that entry: responses must be delivered
    // in accept order (the fetch unit's instruction buffer relies on it).
    logic older_miss[N_CACHE];
    assign older_miss[0] = (|slot_miss_q[0]) || slot_miss_wait[0];
    assign older_miss[1] = (|slot_miss_q[1]) || slot_miss_wait[1];

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            for (int c = 0; c < N_CACHE; c++) begin
                skid_q[c][0]        <= '0;
                skid_q[c][1]        <= '0;
                skid_valid_q[c][0]  <= 1'b0;
                skid_valid_q[c][1]  <= 1'b0;
                slot_lookup_q[c][0] <= 1'b0;
                slot_lookup_q[c][1] <= 1'b0;
                slot_rsp_q[c][0]    <= 1'b0;
                slot_rsp_q[c][1]    <= 1'b0;
                miss_seen_q[c][0]   <= 1'b0;
                miss_seen_q[c][1]   <= 1'b0;
                slot_miss_q[c][0]   <= 1'b0;
                slot_miss_q[c][1]   <= 1'b0;
                rq_q[c][0]          <= '0;
                rq_q[c][1]          <= '0;
                rq_blk_q[c][0]      <= 1'b0;
                rq_blk_q[c][1]      <= 1'b0;
                rq_cnt_q[c]         <= '0;
                cmp_tag_q[c]        <= '0;
                cmp_dw_sel_q[c]     <= '0;
                cmp_we_q[c]         <= 1'b0;
            end
        end else begin
            for (int c = 0; c < N_CACHE; c++) begin
                // Accept: fill the first free slot (wready guarantees one).
                if (cache_accept[c]) begin
                    skid_q[c][slot_free[c]]        <= (c == 0) ? icache_req_i : dcache_req_i;
                    skid_valid_q[c][slot_free[c]]  <= 1'b1;
                    slot_lookup_q[c][slot_free[c]] <= 1'b0;
                    slot_rsp_q[c][slot_free[c]]    <= 1'b0;
                    miss_seen_q[c][slot_free[c]]   <= 1'b0;
                    slot_miss_q[c][slot_free[c]]   <= 1'b0;
                end

                // Lookup launch for the (single) un-launched slot.
                if (cache_lookup_go[c]) begin
                    slot_lookup_q[c][slot_lookup_sel[c]] <= 1'b1;
                    slot_rsp_q[c][slot_lookup_sel[c]]    <= 1'b1;
                    cmp_tag_q[c]                         <= tag[c];
                    cmp_dw_sel_q[c]                      <= dw_sel[c];
                    cmp_we_q[c]                          <= cache_req[c].we;
                end

                // Tag answer for the slot it belongs to (answer order =
                // launch order = accept order).
                if (cache_rsp_pulse[c]) begin
                    slot_rsp_q[c][slot_rsp_sel[c]] <= 1'b0;
                    if (cache_hit_pulse[c]) skid_valid_q[c][slot_rsp_sel[c]] <= 1'b0;
                    else miss_seen_q[c][slot_rsp_sel[c]] <= 1'b1;
                end

                // Response queue. Push+pop collides only at cnt==1 (head
                // consumed and new tail pushed the same cycle, count
                // unchanged); push at cnt==2 is impossible because
                // outstanding <= SKID_DEPTH[c] bounds queue entries.
                if (cache_push[c] && cache_pop[c]) begin
                    rq_q[c][0]     <= cache_push_data[c];
                    rq_blk_q[c][0] <= older_miss[c];
                end else if (cache_push[c]) begin
                    rq_cnt_q[c]                            <= rq_cnt_q[c] + 2'd1;
                    rq_q[c][(rq_cnt_q[c]==2'd0)?0 : 1]     <= cache_push_data[c];
                    rq_blk_q[c][(rq_cnt_q[c]==2'd0)?0 : 1] <= older_miss[c];
                end else if (cache_pop[c]) begin
                    rq_cnt_q[c]    <= rq_cnt_q[c] - 2'd1;
                    rq_q[c][0]     <= rq_q[c][1];
                    rq_blk_q[c][0] <= rq_blk_q[c][1];
                end

                // FSM pickup of the oldest missed slot.
                if (cache_fsm_latch[c]) begin
                    miss_seen_q[c][slot_miss_sel[c]] <= 1'b0;
                    slot_miss_q[c][slot_miss_sel[c]] <= 1'b1;
                end
            end
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
    logic miss_sel;  // 0 = icache, 1 = dcache (the entry the FSM will pick up)
    logic cache_fsm_latch[N_CACHE];

    // A miss is pending from its lookup's response until the FSM latches it
    // (miss_seen_q is a one-shot per request, not a per-cycle level — the
    // FSM will not re-refill the same line forever after returning to
    // S_IDLE). Fixed priority: dcache wins ties (avoids stalling stores);
    // the loser keeps its miss_seen_q slot until the FSM comes back. The
    // FSM pickup does NOT free the skid slot: the slot stays occupied
    // (slot_miss_q) so no younger response can pass the older miss; it is
    // unstalled when the miss completes (S_UPDATE_TAG, TODO Phase 4).
    assign miss_pending = slot_miss_wait[0] || slot_miss_wait[1];
    assign miss_sel     = slot_miss_wait[1];

    wire fsm_latch_miss = (state_q == S_IDLE) && miss_pending;
    assign cache_fsm_latch[0] = fsm_latch_miss && !miss_sel;
    assign cache_fsm_latch[1] = fsm_latch_miss && miss_sel;

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
        sdrc_cmd            = SDRC_CMD_NOP;  // encoding from yarv32_cache_pkg (see TODO there)
        sdrc_addr           = '0;
        sdrc_dqm            = 4'h0;  // all bytes enabled; the FSM never masks
        sdrc_data           = '0;
        sdrc_data_len       = '0;
        sdrc_precharge_ctrl = 1'b0;
        sdram_power_down    = 1'b0;
        sdram_selfrefresh   = 1'b0;

        unique case (state_q)

            S_IDLE: begin
                burst_cnt_d = '0;
                if (miss_pending) begin
                    // Fixed priority: dcache wins ties (avoids stalling
                    // stores). cache_fsm_latch (above) marks the picked-up
                    // slot slot_miss_q; the FSM owns it until the miss
                    // completes.
                    req_sel_d   = miss_sel;
                    miss_addr_d = skid_q[miss_sel][slot_miss_sel[miss_sel]].addr;
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
                sdrc_cmd      = SDRC_CMD_WRITE;
                // Line-aligned burst start: strip the intra-line offset so the
                // burst covers exactly the one 32-byte line being written
                // back (a mid-line miss_addr_q would otherwise straddle two
                // lines). Word address = line byte base >> 2.
                // TODO: bank/row/col mapping for the real IP.
                sdrc_addr     = {miss_addr_q[MEM_SIZE-1:NBIT_OFFSET], {(NBIT_OFFSET - 2) {1'b0}}};
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
                sdrc_cmd      = SDRC_CMD_READ;
                // Line-aligned burst start, same as S_WB_REQ: the refill
                // reads exactly the missing line, word 0 first.
                // TODO: bank/row/col mapping for the real IP.
                sdrc_addr     = {miss_addr_q[MEM_SIZE-1:NBIT_OFFSET], {(NBIT_OFFSET - 2) {1'b0}}};
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
                // Tag field width is TAG_FIELD_W.
                state_d = S_IDLE;
            end

            default: state_d = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------
    // CPU-facing response: the response-queue head.
    //   rvalid is a LEVEL, held until the CPU's rready pops the head
    //   (protocol compliance — the old design exposed the lookup's
    //   one-cycle pulse and lost reads whenever rready was low).
    //   A queue entry pushed while an older miss was unresolved is blocked
    //   (rq_blk_q) until that miss completes — responses are delivered in
    //   accept order, which the fetch unit's instruction buffer relies on.
    //   wready accepts while outstanding (occupied slots + unconsumed
    //   entries) is below the per-port limit: 2 for the I-port's 2
    //   outstanding reads, 1 for the single-outstanding D-port. Hits are
    //   served while the miss FSM is mid-transit; only unresolved-miss
    //   slots gate delivery.
    // -------------------------------------------------------------
    assign icache_rsp_o.wready = (slot_outstanding[0] < SKID_DEPTH[0]);
    assign icache_rsp_o.rvalid = (rq_cnt_q[0] != 2'd0) && !rq_blk_q[0][0];
    assign icache_rsp_o.rdata  = rq_q[0][0];
    assign icache_rsp_o.bvalid = 1'b0;  // posted stores, no B channel

    assign dcache_rsp_o.wready = (slot_outstanding[1] < SKID_DEPTH[1]);
    assign dcache_rsp_o.rvalid = (rq_cnt_q[1] != 2'd0) && !rq_blk_q[1][0];
    assign dcache_rsp_o.rdata  = rq_q[1][0];
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

`endif

endmodule

`resetall
