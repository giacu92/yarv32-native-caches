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

    // SDRAM Interface (external pins, driven by the internal sdram_controller)
    output wire        sdram_clk_o,    // SDRAM clock (TODO: PLL phase shift for the FPGA)
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

    // SDRAM controller host interface (sdram_controller, src/ips submodule):
    // one 32-bit word per transaction, accepted in IDLE (busy rises one
    // cycle after the accept edge); a read completes with a one-cycle
    // rd_ready pulse carrying rd_data, a write completes when busy falls.
    logic sdram_rd_en;
    logic sdram_wr_en;
    logic sdram_busy;
    logic sdram_rd_ready;
    logic [20:0] sdram_rd_addr;  // 32-bit word address {bank, row, col}
    logic [20:0] sdram_wr_addr;
    logic [31:0] sdram_rd_data;
    logic [31:0] sdram_wr_data;

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
    // blocks younger queue entries until the miss completes (unstall)

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

    // Victim state for a missed slot, captured at its lookup pulse (the only
    // cycle the tag answers are guaranteed current — a later lookup on the
    // tag macro overwrites rdata_q). Round-robin victim selection per set:
    // prefer an invalid way, else the rr pointer, which advances on every
    // miss of that set.
    logic [N_SETS-1:0] rr_q[N_CACHE];
    logic [NBIT_WAY-1:0] victim_way_q[N_CACHE][N_SLOT];
    logic victim_valid_q[N_CACHE][N_SLOT];
    logic victim_dirty_q[N_CACHE][N_SLOT];
    logic [TAG_FIELD_W-1:0] victim_tag_q[N_CACHE][N_SLOT];

    int rsp_set[N_CACHE];  // set of the slot whose lookup answer is arriving
    int rsp_victim_way[N_CACHE];  // victim way chosen for that answer

    // Miss-FSM macro access + unstall handshake with the skid/queue logic
    // above. All are driven by the FSM section below (or the store-hit path
    // next to it); declared here so the macro request muxes and the skid
    // always_ff can reference them.
    logic fsm_lookup_gate[N_CACHE];  // FSM owns this cache's macros: hold lookups
    logic fsm_unstall[N_CACHE];  // completed miss frees its slot (one cycle)
    logic [$clog2(N_SLOT)-1:0] fsm_unstall_slot;  // slot being unstalled
    logic fsm_rsp_push[N_CACHE];  // completed miss was a load: push its response
    logic [MEM_WIDTH-1:0] fsm_rsp_data;  // response data from the refilled line
    int fsm_victim_way;  // victim way the FSM operates on
    way_req_t fsm_way_req;  // FSM request to the data macros
    tag_req_t fsm_tag_req;  // FSM request to the tag macros
    logic fsm_imem_access, fsm_dmem_access;  // FSM drives the data macros
    logic fsm_itag_write, fsm_dtag_write;  // FSM drives the tag macros
    logic [DATA_WIDTH-1:0] fsm_victim_line;  // victim line read back for WB
    logic [DATA_WIDTH-1:0] commit_line;  // refilled line (+ store merge)
    logic miss_is_store;  // the missed request is a store (write-allocate)
    logic dcache_store_hit;  // posted store hit: data+tag writes land now
    int dhit_way;  // hit way of the store above
    way_req_t dstore_way_req;
    tag_req_t dstore_tag_req;

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

            // Context of the lookup answer arriving this cycle (if any):
            // its set and the victim way chosen for it. The tag macros'
            // rdata is only current while their rvalid pulses, so both are
            // consumed by the miss-pulse capture below, never sampled cold.
            rsp_set[c] = 32'(skid_q[c][slot_rsp_sel[c]].addr[NBIT_OFFSET+:NBIT_SET_IDX]);
            rsp_victim_way[c] = 32'(rr_q[c][rsp_set[c]]);
            for (int i = N_WAY - 1; i >= 0; i--) begin
                if ((c == 0) ? !itag_rsp[i].rdata[0] : !dtag_rsp[i].rdata[0]) begin
                    rsp_victim_way[c] = i;
                end
            end
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
            // Hold lookups while the miss FSM is accessing this cache's
            // data/tag macros (fsm_lookup_gate): a lookup launch would
            // clobber the victim-line read held in the macro's rdata_q, or
            // race the line/tag commit. Lookups on the OTHER cache and
            // accepts/wready are unaffected — hits-under-miss resume during
            // the (long) refill states, which do not touch the macros.
            cache_lookup_go[c] = ((skid_valid_q[c][0] && !slot_lookup_q[c][0]) ||
                                  (skid_valid_q[c][1] && !slot_lookup_q[c][1])) &&
                !fsm_lookup_gate[c];
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

    // SDRAM controller (src/ips/sdram-controller submodule, BSD; the
    // gw2ar-32bit branch adapts it to the GW2AR-18 embedded SDRAM: 32-bit
    // data, row/col/bank 11/8/2, CL=3, burst length 1 with auto-precharge
    // — one host word per transaction, refresh handled internally).
    // TODO (FPGA): pick the real system clock + CLK_FREQUENCY (refresh
    // spacing) and the O_sdram_clk phase alignment.
    sdram_controller #(
        .ROW_WIDTH    (11),
        .COL_WIDTH    (8),
        .BANK_WIDTH   (2),
        .DATA_WIDTH   (32),
        .CLK_FREQUENCY(100)
    ) u_sdram_cntrl (
        .wr_addr     (sdram_wr_addr),
        .wr_data     (sdram_wr_data),
        .wr_enable   (sdram_wr_en),
        .rd_addr     (sdram_rd_addr),
        .rd_data     (sdram_rd_data),
        .rd_ready    (sdram_rd_ready),
        .rd_enable   (sdram_rd_en),
        .busy        (sdram_busy),
        .rst_n       (rstn_i),
        .clk         (clk_i),
        .addr        (sdram_addr_o),
        .bank_addr   (sdram_ba_o),
        .data        (sdram_dq_io),
        .clock_enable(sdram_cke_o),
        .cs_n        (sdram_cs_n_o),
        .ras_n       (sdram_ras_n_o),
        .cas_n       (sdram_cas_n_o),
        .we_n        (sdram_wen_n_o),
        .dqm         (sdram_dqm_o)
    );

    assign sdram_clk_o = clk_i;


    // ===================================================================
    // Cache controller logic (hit/miss, refill, write-back, arbitration)
    // ===================================================================

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

        // Miss-FSM tag write (S_UPDATE_TAG): store the refilled line's tag
        // into the victim way. CPU lookups for this cache are gated off in
        // that state (fsm_lookup_gate), so the mux below never has to
        // arbitrate two drivers.
        if (fsm_itag_write) itag_req[fsm_victim_way] = fsm_tag_req;

        // Posted store hit: set the dirty bit in the hit way's tag word the
        // same cycle the tag answer pulses (D-port is single-outstanding, so
        // no CPU lookup can be launching in this cycle). Else: miss-FSM tag
        // write as above.
        if (dcache_store_hit) dtag_req[dhit_way] = dstore_tag_req;
        else if (fsm_dtag_write) dtag_req[fsm_victim_way] = fsm_tag_req;
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
            dmem_req[i].we     = 1'b0;  // lookup only; writes come from the store path / FSM
            dmem_req[i].wstrb  = '0;
            dmem_req[i].addr   = cache_req[1].addr;
            dmem_req[i].rready = 1'b1;
        end

        // Miss-FSM data-macro access: S_WB_READ reads the victim line out of
        // the victim way, S_UPDATE_TAG commits the refilled line into it.
        if (fsm_imem_access) imem_req[fsm_victim_way] = fsm_way_req;

        // Posted store hit: byte-strobe write into the hit way (see
        // dstore_way_req). Else: miss-FSM access as above. The two are
        // mutually exclusive: while the FSM owns a dcache miss its single
        // slot is occupied, so no dcache lookup (store hit included) can
        // pulse.
        if (dcache_store_hit) dmem_req[dhit_way] = dstore_way_req;
        else if (fsm_dmem_access) dmem_req[fsm_victim_way] = fsm_way_req;
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
                skid_q[c][0]         <= '0;
                skid_q[c][1]         <= '0;
                skid_valid_q[c][0]   <= 1'b0;
                skid_valid_q[c][1]   <= 1'b0;
                slot_lookup_q[c][0]  <= 1'b0;
                slot_lookup_q[c][1]  <= 1'b0;
                slot_rsp_q[c][0]     <= 1'b0;
                slot_rsp_q[c][1]     <= 1'b0;
                miss_seen_q[c][0]    <= 1'b0;
                miss_seen_q[c][1]    <= 1'b0;
                slot_miss_q[c][0]    <= 1'b0;
                slot_miss_q[c][1]    <= 1'b0;
                rq_q[c][0]           <= '0;
                rq_q[c][1]           <= '0;
                rq_blk_q[c][0]       <= 1'b0;
                rq_blk_q[c][1]       <= 1'b0;
                rq_cnt_q[c]          <= '0;
                cmp_tag_q[c]         <= '0;
                cmp_dw_sel_q[c]      <= '0;
                cmp_we_q[c]          <= 1'b0;
                rr_q[c]              <= '0;
                victim_way_q[c][0]   <= '0;
                victim_way_q[c][1]   <= '0;
                victim_valid_q[c][0] <= 1'b0;
                victim_valid_q[c][1] <= 1'b0;
                victim_dirty_q[c][0] <= 1'b0;
                victim_dirty_q[c][1] <= 1'b0;
                victim_tag_q[c][0]   <= '0;
                victim_tag_q[c][1]   <= '0;
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
                // launch order = accept order). On a miss, capture the
                // victim for THIS slot at the pulse (the only cycle the tag
                // answers are current) and advance the set's round-robin
                // pointer — per-slot, so a second miss of the same cache
                // waiting in the other slot cannot clobber the first.
                if (cache_rsp_pulse[c]) begin
                    slot_rsp_q[c][slot_rsp_sel[c]] <= 1'b0;
                    if (cache_hit_pulse[c]) begin
                        skid_valid_q[c][slot_rsp_sel[c]] <= 1'b0;
                    end else begin
                        miss_seen_q[c][slot_rsp_sel[c]] <= 1'b1;
                        victim_way_q[c][slot_rsp_sel[c]] <= NBIT_WAY'(rsp_victim_way[c]);
                        victim_valid_q[c][slot_rsp_sel[c]] <= (c == 0) ? itag_rsp[
                            rsp_victim_way[c]].rdata[0] : dtag_rsp[rsp_victim_way[c]].rdata[0];
                        victim_dirty_q[c][slot_rsp_sel[c]] <= (c == 0) ? itag_rsp[
                            rsp_victim_way[c]].rdata[1] : dtag_rsp[rsp_victim_way[c]].rdata[1];
                        victim_tag_q[c][slot_rsp_sel[c]] <= (c == 0) ?
                            itag_rsp[rsp_victim_way[c]].rdata[2+:TAG_FIELD_W] :
                            dtag_rsp[rsp_victim_way[c]].rdata[2+:TAG_FIELD_W];
                        rr_q[c][rsp_set[c]] <= ~rr_q[c][rsp_set[c]];
                    end
                end

                // FSM unstall (S_UNSTALL cycle): the completed miss's slot is
                // freed (its outstanding unit with it) and entries latched
                // blocked behind the miss are unblocked. A load miss's
                // response is inserted in ACCEPT order: an unblocked head is
                // OLDER than the miss (pushed before it entered transit), a
                // blocked head is YOUNGER — the response goes behind the
                // former and in front of the latter. The queue holds at most
                // one entry while the missed slot is still occupied
                // (outstanding <= SKID_DEPTH), so a same-cycle pop can only
                // be the unblocked-head case. No CPU push can collide: the
                // lookups were gated during S_UPDATE_TAG, so no answer pulse
                // fires this cycle.
                if (fsm_unstall[c]) begin
                    skid_valid_q[c][fsm_unstall_slot] <= 1'b0;
                    slot_miss_q[c][fsm_unstall_slot]  <= 1'b0;
                    rq_blk_q[c][0]                    <= 1'b0;
                    rq_blk_q[c][1]                    <= 1'b0;
                    if (fsm_rsp_push[c]) begin
                        if (cache_pop[c]) begin
                            // Unblocked head consumed this cycle: take its place.
                            rq_q[c][0] <= fsm_rsp_data;
                        end else if (rq_cnt_q[c] == 2'd0) begin
                            rq_cnt_q[c] <= rq_cnt_q[c] + 2'd1;
                            rq_q[c][0]  <= fsm_rsp_data;
                        end else if (!rq_blk_q[c][0]) begin
                            // Older entry at the head: miss response goes behind it.
                            rq_cnt_q[c] <= rq_cnt_q[c] + 2'd1;
                            rq_q[c][1]  <= fsm_rsp_data;
                        end else begin
                            // Younger entry latched blocked behind the miss:
                            // the (older) miss response goes in front of it.
                            rq_cnt_q[c] <= rq_cnt_q[c] + 2'd1;
                            rq_q[c][1]  <= rq_q[c][0];
                            rq_q[c][0]  <= fsm_rsp_data;
                        end
                    end
                end else if (cache_push[c] && cache_pop[c]) begin
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
    // Hits never enter this FSM (they're served by the skid/queue logic
    // above); only a miss triggers arbitration for the shared SDRAM
    // controller. Flow: latch the oldest missed slot (S_IDLE), pick the
    // victim (captured at the miss pulse; prefer an invalid way, else
    // per-set round-robin), write back a dirty valid victim to the VICTIM's
    // SDRAM address, refill the missing line, commit line + tag into the
    // victim way, then unstall the requester (free the slot, push the
    // response in accept order) and return to S_IDLE.
    //
    // SDRAM access model (sdram_controller host interface): one 32-bit
    // word per transaction, no bursts. Refill = BURST_LEN single-word
    // reads, writeback = BURST_LEN single-word writes. Handshake: an
    // enable is held until busy rises (accept; refresh may delay it),
    // a read completes on the rd_ready pulse, a write when busy falls —
    // no placeholder completion signals.

    localparam int BURST_LEN = DATA_WIDTH / 32;  // 32-bit SDRAM data bus

    typedef enum logic [3:0] {
        S_IDLE,
        S_ARBITRATE,
        S_WB_READ,  // read the victim line out of its data macro
        S_WB_ISSUE,  // writeback word handshake; skipped if victim not dirty
        S_WB_WAIT,  // wait for the accepted write word to complete
        S_REFILL_ISSUE,  // refill word read handshake
        S_REFILL_WAIT,  // wait for rd_ready, capture the word
        S_UPDATE_TAG,  // commit line + tag into the victim way
        S_UNSTALL  // free the missed slot, deliver the response
    } fsm_state_e;

    fsm_state_e state_q, state_d;

    logic req_sel_q, req_sel_d;  // 0 = icache, 1 = dcache
    logic [3:0] burst_cnt_q, burst_cnt_d;  // 0 .. BURST_LEN-1
    logic [DATA_WIDTH-1:0] line_buf_q, line_buf_d;  // staged/assembled cache line
    logic [MEM_WIDTH-1:0] miss_addr_q, miss_addr_d;
    logic [$clog2(N_SLOT)-1:0] miss_slot_q, miss_slot_d;  // skid slot the FSM owns

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
            miss_slot_q <= '0;
        end else begin
            state_q     <= state_d;
            req_sel_q   <= req_sel_d;
            burst_cnt_q <= burst_cnt_d;
            line_buf_q  <= line_buf_d;
            miss_addr_q <= miss_addr_d;
            miss_slot_q <= miss_slot_d;
        end
    end

    // Line-aligned byte addresses: writeback targets the VICTIM's line
    // {victim_tag, set, offset 0} — NOT the missing address (that would
    // overwrite the missing line's own SDRAM location with victim data);
    // refill reads the missing line itself. The controller's host address
    // is the 32-bit word index {bank, row, col} = byte_addr[22:2], so the
    // per-word index is the line base word + burst_cnt_q.
    logic [22:0] wb_byte_addr, refill_byte_addr;
    assign wb_byte_addr = {
        victim_tag_q[req_sel_q][miss_slot_q],
        miss_addr_q[NBIT_OFFSET+:NBIT_SET_IDX],
        {NBIT_OFFSET{1'b0}}
    };
    assign refill_byte_addr = {miss_addr_q[MEM_SIZE-1:NBIT_OFFSET], {NBIT_OFFSET{1'b0}}};

    always_comb begin
        // defaults: hold state / datapath
        state_d       = state_q;
        req_sel_d     = req_sel_q;
        burst_cnt_d   = burst_cnt_q;
        line_buf_d    = line_buf_q;
        miss_addr_d   = miss_addr_q;
        miss_slot_d   = miss_slot_q;

        sdram_rd_en   = 1'b0;
        sdram_wr_en   = 1'b0;
        sdram_wr_addr = wb_byte_addr[MEM_SIZE-1:2] + {17'd0, burst_cnt_q};
        sdram_wr_data = fsm_victim_line[burst_cnt_q*32+:32];
        sdram_rd_addr = refill_byte_addr[MEM_SIZE-1:2] + {17'd0, burst_cnt_q};

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
                    miss_slot_d = $clog2(N_SLOT)'(slot_miss_sel[miss_sel]);
                    state_d     = S_ARBITRATE;
                end
            end

            S_ARBITRATE: begin
                // Victim way/tag/dirty were captured at the miss's lookup
                // pulse (victim_*_q, per slot — see the skid block). Only a
                // valid AND dirty victim needs its line written back before
                // the refill overwrites the way.
                burst_cnt_d = '0;
                state_d = (victim_valid_q[req_sel_q][miss_slot_q] &&
                           victim_dirty_q[req_sel_q][miss_slot_q]) ? S_WB_READ : S_REFILL_ISSUE;
            end

            S_WB_READ: begin
                // The data-macro read of the victim line is driven by the
                // FSM request mux (fsm_way_req): it launches this cycle and
                // the data is valid from S_WB_ISSUE on, held in the macro's
                // rdata_q (lookups are gated through S_WB_WAIT, so no other
                // read can clobber it).
                state_d = S_WB_ISSUE;
            end

            S_WB_ISSUE: begin
                // Present the write word until the controller accepts it
                // (busy rises a cycle after the accept edge; a due refresh
                // delays the accept, so hold, don't pulse). Deassert on
                // accept: an enable still up when the controller returns to
                // IDLE would be latched as another request.
                sdram_wr_en = !sdram_busy;
                if (sdram_busy) state_d = S_WB_WAIT;
            end

            S_WB_WAIT: begin
                // The accepted word is done when busy falls (the controller
                // sits in IDLE again). Advance to the next word, or to the
                // refill once the whole line is out.
                if (!sdram_busy) begin
                    // Zero-extend so the 4-bit counter compares width-clean
                    // against the 32-bit int localparam.
                    if ({28'd0, burst_cnt_q} == BURST_LEN - 1) begin
                        burst_cnt_d = '0;
                        state_d     = S_REFILL_ISSUE;
                    end else begin
                        burst_cnt_d = burst_cnt_q + 1'b1;
                        state_d     = S_WB_ISSUE;
                    end
                end
            end

            S_REFILL_ISSUE: begin
                // Present the read word address until accepted (see
                // S_WB_ISSUE on the hold-vs-pulse question).
                sdram_rd_en = !sdram_busy;
                if (sdram_busy) state_d = S_REFILL_WAIT;
            end

            S_REFILL_WAIT: begin
                // The controller's per-word data-valid strobe: rd_ready is a
                // one-cycle pulse carrying the word on rd_data.
                if (sdram_rd_ready) begin
                    line_buf_d[burst_cnt_q*32+:32] = sdram_rd_data;
                    if ({28'd0, burst_cnt_q} == BURST_LEN - 1) state_d = S_UPDATE_TAG;
                    else begin
                        burst_cnt_d = burst_cnt_q + 1'b1;
                        state_d     = S_REFILL_ISSUE;
                    end
                end
            end

            S_UPDATE_TAG: begin
                // One cycle: the data-macro line commit and the tag write are
                // driven by the FSM request muxes (fsm_way_req / fsm_tag_req,
                // below) and commit at this cycle's edge (posted native_ram
                // writes). Lookups were gated this cycle, so the next lookup
                // launched on this cache sees the committed line and tag.
                state_d = S_UNSTALL;
            end

            S_UNSTALL: begin
                // Unstall is a wire (fsm_unstall), acted on by the skid block
                // at this cycle's edge: the missed slot is freed, a load
                // miss's response is pushed onto the queue in accept order,
                // and entries latched blocked behind the miss are unblocked.
                state_d = S_IDLE;
            end

            default: state_d = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------
    // FSM datapath muxes (declared with the signals above, driven here
    // after the FSM state they depend on).
    // -------------------------------------------------------------

    // Victim line as read back in S_WB_READ: held in the victim way's
    // rdata_q through S_WB_ISSUE/S_WB_WAIT (lookups are gated, so no other
    // read can overwrite it).
    assign fsm_victim_line = (req_sel_q == 1'b0) ? imem_rsp_d[fsm_victim_way].rdata :
        dmem_rsp_d[fsm_victim_way].rdata;

    // The missed request is a store: write-allocate — the line is committed
    // with the store already merged, so it lands dirty.
    assign miss_is_store = skid_q[req_sel_q][miss_slot_q].we;

    always_comb begin
        commit_line = line_buf_q;
        if (miss_is_store) begin
            for (int b = 0; b < MEM_WIDTH / 8; b++) begin
                if (skid_q[req_sel_q][miss_slot_q].wstrb[b]) begin
                    commit_line[miss_addr_q[NBIT_OFFSET-1:3]*64+b*8+:8] =
                        skid_q[req_sel_q][miss_slot_q].wdata[b*8+:8];
                end
            end
        end
    end

    // FSM requests to the data/tag macros of the cache being serviced
    // (req_sel_q). Lookups on that cache are gated while these are active,
    // so the muxes in the macro request blocks never arbitrate two drivers.
    always_comb begin
        fsm_victim_way  = 32'(victim_way_q[req_sel_q][miss_slot_q]);
        fsm_way_req     = '0;
        fsm_tag_req     = '0;
        fsm_imem_access = 1'b0;
        fsm_dmem_access = 1'b0;
        fsm_itag_write  = 1'b0;
        fsm_dtag_write  = 1'b0;

        case (state_q)
            S_WB_READ: begin
                // Read the victim line out of the victim way's data macro.
                // Line base = {victim_tag, set, offset 0}; the macro decodes
                // only the set bits (word_addr = addr[WAY_ADDR_W-1:BYTES_W]).
                if (req_sel_q == 1'b0) fsm_imem_access = 1'b1;
                else fsm_dmem_access = 1'b1;
                fsm_way_req.valid = 1'b1;
                fsm_way_req.we = 1'b0;
                fsm_way_req.addr = {
                    {(MEM_WIDTH - MEM_SIZE) {1'b0}},
                    victim_tag_q[req_sel_q][miss_slot_q],
                    miss_addr_q[NBIT_OFFSET+:NBIT_SET_IDX],
                    {NBIT_OFFSET{1'b0}}
                };
                fsm_way_req.rready = 1'b1;
            end

            S_UPDATE_TAG: begin
                // Line commit + tag write to the victim way (both posted at
                // this cycle's edge). Tag = {tag, dirty, valid} of the missing
                // address; dirty is set only if the missing request was a
                // store (write-allocate, merged into commit_line above).
                if (req_sel_q == 1'b0) begin
                    fsm_imem_access = 1'b1;
                    fsm_itag_write  = 1'b1;
                end else begin
                    fsm_dmem_access = 1'b1;
                    fsm_dtag_write  = 1'b1;
                end

                fsm_way_req.valid = 1'b1;
                fsm_way_req.we = 1'b1;
                // Line commit at the missing address itself (zero-extended);
                // the macro decodes word_addr = addr[11:5] = set, exactly as
                // the CPU lookups do.
                fsm_way_req.addr = {{(MEM_WIDTH - MEM_SIZE) {1'b0}}, miss_addr_q[MEM_SIZE-1:0]};
                fsm_way_req.wdata = commit_line;
                fsm_way_req.wstrb = {(DATA_WIDTH / 8) {1'b1}};
                fsm_way_req.rready = 1'b1;

                fsm_tag_req.valid = 1'b1;
                fsm_tag_req.we = 1'b1;
                // Same set-index shift as the lookup requests.
                fsm_tag_req.addr = {
                    {(MEM_WIDTH - NBIT_SET_IDX - TAG_BYTES_W) {1'b0}},
                    miss_addr_q[NBIT_OFFSET+:NBIT_SET_IDX],
                    {TAG_BYTES_W{1'b0}}
                };
                fsm_tag_req.wdata = {
                    {(TAG_DATA_W - TAG_FIELD_W - 2) {1'b0}},
                    miss_addr_q[MEM_SIZE-1-:TAG_FIELD_W],
                    miss_is_store,
                    1'b1
                };
                fsm_tag_req.wstrb = {(TAG_DATA_W / 8) {1'b1}};
                fsm_tag_req.rready = 1'b1;
            end

            default: ;
        endcase
    end

    // Lookups on the cache the FSM is servicing are held while the FSM
    // touches its macros: S_WB_READ..S_WB_WAIT hold the victim line in the
    // data macro's rdata_q (the writeback streams out of it word by word),
    // S_UPDATE_TAG commits the line+tag writes. S_REFILL_* leave the macros
    // alone, so hits resume during the long refill phase.
    logic fsm_macro_state;
    assign fsm_macro_state = (state_q == S_WB_READ) || (state_q == S_WB_ISSUE) ||
        (state_q == S_WB_WAIT) || (state_q == S_UPDATE_TAG);
    assign fsm_lookup_gate[0] = fsm_macro_state && (req_sel_q == 1'b0);
    assign fsm_lookup_gate[1] = fsm_macro_state && (req_sel_q == 1'b1);

    // Unstall (S_UNSTALL cycle): free the missed slot; a load miss pushes
    // its response — the refilled line's doubleword — in accept order.
    assign fsm_unstall_slot = miss_slot_q;
    assign fsm_unstall[0] = (state_q == S_UNSTALL) && (req_sel_q == 1'b0);
    assign fsm_unstall[1] = (state_q == S_UNSTALL) && (req_sel_q == 1'b1);
    assign fsm_rsp_push[0] = fsm_unstall[0] && !skid_q[0][miss_slot_q].we;
    assign fsm_rsp_push[1] = fsm_unstall[1] && !skid_q[1][miss_slot_q].we;
    assign fsm_rsp_data = line_buf_q[miss_addr_q[NBIT_OFFSET-1:3]*64+:64];

    // -------------------------------------------------------------
    // D-cache store hit (posted). The data-macro write into the hit way and
    // the dirty-bit tag write fire the same cycle the tag answer pulses.
    // Byte strobes are positioned at the store's doubleword
    // (cmp_dw_sel_q), so only the addressed bytes of the line are touched;
    // the rest of the wdata is don't-care (strobed off). The I-port is
    // read-only by spec: a we=1 request there is a posted no-op.
    // -------------------------------------------------------------
    assign dcache_store_hit = cache_rsp_pulse[1] && cache_hit_pulse[1] && cmp_we_q[1];

    always_comb begin
        dhit_way = 0;
        for (int i = N_WAY - 1; i >= 0; i--) begin
            if (dcache_way_hit[i]) dhit_way = i;
        end
    end

    always_comb begin
        dstore_way_req = '0;
        dstore_way_req.valid = dcache_store_hit;
        dstore_way_req.we = 1'b1;
        dstore_way_req.addr = skid_q[1][slot_rsp_sel[1]].addr;
        dstore_way_req.wdata = '0;
        dstore_way_req.wdata[cmp_dw_sel_q[1]*64+:64] = skid_q[1][slot_rsp_sel[1]].wdata;
        dstore_way_req.wstrb = {{(DATA_WIDTH / 8 - MEM_WIDTH / 8) {1'b0}},
                                skid_q[1][slot_rsp_sel[1]].wstrb} << (cmp_dw_sel_q[1] * 8);
        dstore_way_req.rready = 1'b1;

        dstore_tag_req = '0;
        dstore_tag_req.valid = dcache_store_hit;
        dstore_tag_req.we = 1'b1;
        dstore_tag_req.addr = {
            {(MEM_WIDTH - NBIT_SET_IDX - TAG_BYTES_W) {1'b0}},
            skid_q[1][slot_rsp_sel[1]].addr[NBIT_OFFSET+:NBIT_SET_IDX],
            {TAG_BYTES_W{1'b0}}
        };
        // Same tag value as the hit (cmp_tag_q, by definition of the hit),
        // with dirty+valid set.
        dstore_tag_req.wdata = {{(TAG_DATA_W - TAG_FIELD_W - 2) {1'b0}}, cmp_tag_q[1], 2'b11};
        dstore_tag_req.wstrb = {(TAG_DATA_W / 8) {1'b1}};
        dstore_tag_req.rready = 1'b1;
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
