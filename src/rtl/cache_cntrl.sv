`resetall
`timescale 1ns / 1ps
`default_nettype none

import yarv32_cache_pkg::*;

/**
 * Cache line size: 32 byte
 * I-Cache size: 8 KiB - D-Cache size: 8 KiB = 16 KiB total
 * 8 MiB SDRAM (GW2AR Internal) --> Address is 23 bit wide
 * addr = {tag, set_idx, offset} (classic bit-slice set index)
 * CPU access widths: I port 64 bit (doubleword select, addr[NBIT_OFFSET-1:3]),
 * D port 32 bit (word select, addr[NBIT_OFFSET-1:2]) — see yarv32-uc's
 * ifetch_req_t / mem_req_t port types in the package.
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
    parameter int CACHE_SIZE = 13,  // 2^13 = 8 KiB
    // System clock frequency in MHz. Only used to space the SDRAM refresh
    // bursts (sdram_controller's CYCLES_BETWEEN_REFRESH); it must match the
    // real clk_i rate or the SDRAM is refreshed too rarely (data loss) or
    // too often (wasted bandwidth). Sim runs at 100 MHz (10 ns period in
    // sim_top); the Tang Nano 20K build passes 50 (see fpga_top).
    parameter int CLK_FREQ_MHZ = 100,
    // SDRAM power-up wait, in microseconds. JEDEC SDRAM (and the GW2AR's
    // embedded die) requires stable clock and NOP-only for at least 100 us
    // after power-up before it will accept PRECHARGE / REFRESH / MRS. The
    // controller only counts 15 cycles of its own (300 ns at 50 MHz), so
    // its reset is held here until the wait has elapsed; while it is in
    // reset it drives NOP, which is exactly what the chip wants to see.
    // Skipping this is invisible in simulation but leaves a real device
    // with an unprogrammed mode register and undefined reads.
    parameter int SDRAM_INIT_US = 200,
    // Optional $readmemh image for the bootrom (2 KiB, 256 x 64 bit).
    // Empty means an uninitialised macro: legal, but it reads back
    // whatever the device powered up with.
    parameter string BOOTROM_FILE = "",
    // Power-on value of the control register (see CSR_W / CSR_BIT_BYPASS
    // in the package). Default 0: caches enabled, bypass off — the
    // behaviour of the design before the register existed.
    parameter logic [CSR_W-1:0] CSR_RST_VAL = '0
) (
    input wire clk_i,
    input wire rstn_i,

    // Clock forwarded to the SDRAM's own clock pin. On the FPGA this is a
    // phase-shifted copy of clk_i (the chip samples the command/data pins
    // on ITS clock edge, so the shift is what buys setup/hold margin
    // across the SIP wiring); in sim it is simply clk_i.
    input wire sdram_clk_i,

    // ICACHE Interface (fetch port: read-only, 64-bit, 2 outstanding)
    input  ifetch_req_t icache_req_i,
    output ifetch_rsp_t icache_rsp_o,

    // DCACHE Interface (LSU port: 32-bit read/write, single-outstanding)
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
    inout  wire [31:0] sdram_dq_io,    // IO_sdram_dq

    // Debug: the miss FSM's current state (fsm_state_e). Board bring-up
    // has no other way to see where a miss got stuck — see fpga_top, which
    // puts this on the LEDs when the self test fails.
    output wire [3:0] dbg_state_o,

    // Debug: why the D port is (not) accepting. A stalled port waits either
    // on its own skid slot or on the miss FSM, and these bits say which:
    //   [3] slot 0 occupied   [2] lookup launched for it
    //   [1] slot missed, waiting for the FSM to pick it up
    //   [0] the response queue holds an unconsumed entry
    output wire [3:0] dbg_dport_o,

    // Debug: D-cache event counters, saturating at 15, in the order a
    // request passes through them — lookups launched, tag answers seen,
    // misses picked up by the FSM, misses unstalled. The final state alone
    // cannot say whether a wedged port never got an answer, got one and
    // lost it, or completed a refill that failed to free the slot; these
    // separate the three in one run.
    //   [3:0] lookups  [7:4] tag answers  [11:8] misses  [15:12] unstalls
    output wire [15:0] dbg_cnt_o,

    // Debug: D-port accepts, saturating at 15. A control counter — the
    // skid slot cannot be occupied without an accept, so a zero here means
    // the counters (or the path that reports them) are lying, not that the
    // event never happened.
    output wire [3:0] dbg_acc_o,

    // Debug, live: the lookup issue path.
    //   [3] cache_lookup_go[1]   [2] fsm_lookup_gate[1]
    //   [1] dtag_req[0].valid    [0] dtag_rsp[0].wready
    output wire [3:0] dbg_go_o,

    // Debug, live: the macro answers this cache is waiting for.
    //   [3] dtag_rsp[0].rvalid   [2] dmem_rsp_d[0].rvalid
    //   [1] slot_rsp_q[1][0]     [0] slot_rsp_q[1][1]
    output wire [3:0] dbg_rsp_o,

    // Debug: free-running tick, incremented every clock with no condition
    // attached. It answers the one question every other counter leaves
    // open — whether this module's flops are advancing at all. A value
    // that never changes between report lines means no clock or a reset
    // held low, and every zero counter elsewhere then says nothing about
    // the design.
    output wire [3:0] dbg_tick_o,

    // Debug: a slow bit of the same free-running tick, for an LED. It
    // reaches a pin through nothing but a flop and a wire — no counters,
    // no report path, no UART. If this LED does not blink while the
    // board's other one does, this module is not being clocked, and that
    // conclusion depends on no other logic being correct.
    output wire dbg_hb_o
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
    // this module's own geometry. way_*_t is one whole cache line wide;
    // tag_*_t is one tag word wide. This keeps the native_ram port widths
    // and the arrays below matched by construction for any
    // CL_SIZE / N_WAY / CACHE_SIZE parameterization.
    `YARV_MEM_TYPES(way_req_t, way_rsp_t, yarv32_cache_pkg::NATIVE_ADDR_W, DATA_WIDTH)
    `YARV_MEM_TYPES(tag_req_t, tag_rsp_t, yarv32_cache_pkg::NATIVE_ADDR_W, TAG_DATA_W)

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
        // CPU-facing type shape pins: these are hand-declared to be
        // bit-identical to the yarv32-uc core's rv32_pkg typedefs, so a
        // field-order or width drift there silently misconnects (a
        // struct-to-struct connection is a packed-vector copy). Pin the
        // packed widths the core's docs state.
        assert ($bits(yarv32_cache_pkg::ifetch_req_t) == 34)
        else
            $fatal(
                1,
                "ifetch_req_t is %0d bits, rv32_pkg says 34",
                $bits(
                    yarv32_cache_pkg::ifetch_req_t
                )
            );
        assert ($bits(yarv32_cache_pkg::ifetch_rsp_t) == 66)
        else
            $fatal(
                1,
                "ifetch_rsp_t is %0d bits, rv32_pkg says 66",
                $bits(
                    yarv32_cache_pkg::ifetch_rsp_t
                )
            );
        assert ($bits(yarv32_cache_pkg::mem_req_t) == 71)
        else
            $fatal(
                1, "mem_req_t is %0d bits, rv32_pkg says 71", $bits(yarv32_cache_pkg::mem_req_t)
            );
        assert ($bits(yarv32_cache_pkg::mem_rsp_t) == 35)
        else
            $fatal(
                1, "mem_rsp_t is %0d bits, rv32_pkg says 35", $bits(yarv32_cache_pkg::mem_rsp_t)
            );
    end
`endif

    // ===================================================================
    // Signal declarations
    // ===================================================================

    boot_req_t bootr_req;  // towards bootrom (64-bit data: the I port fetches 8 bytes)
    boot_rsp_t bootr_rsp;  // from bootrom

    way_req_t [N_WAY-1:0] imem_req;  // towards icache ways
    way_rsp_t [N_WAY-1:0] imem_rsp_d;  // from icache ways
    way_req_t [N_WAY-1:0] dmem_req;  // towards dcache ways
    way_rsp_t [N_WAY-1:0] dmem_rsp_d;  // from dcache ways

    tag_req_t [N_WAY-1:0] itag_req;  // towards itag ways
    tag_rsp_t [N_WAY-1:0] itag_rsp;  // from itag ways
    tag_req_t [N_WAY-1:0] dtag_req;  // towards dtag ways
    tag_rsp_t [N_WAY-1:0] dtag_rsp;  // from dtag ways

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

    // Command interface to sdram_line_port, which owns those nets and
    // turns them into "move N consecutive words" for the miss FSM.
    logic eng_cmd_valid;
    logic eng_cmd_ready;
    logic eng_cmd_we;
    logic [3:0] eng_cmd_words;
    logic [MEM_SIZE-1:2] eng_cmd_addr;
    logic [DATA_WIDTH-1:0] eng_cmd_wdata;  // must hold until eng_done
    logic eng_done;
    logic [DATA_WIDTH-1:0] eng_rdata;  // words captured by the last read

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

    // The two ports carry different request types now (the I port is
    // read-only, 64-bit data; the D port is 32-bit, byte-strobed), so the
    // skid slots split per port. Everything else indexed [cache][slot]
    // below stays a shared packed vector.
    ifetch_req_t [N_SLOT-1:0] iskid_q;  // accepted I requests (skid slots)
    mem_req_t [N_SLOT-1:0] dskid_q;  // accepted D requests (skid slots)
    logic [N_CACHE-1:0][N_SLOT-1:0] skid_valid_q;  // slot occupied
    logic [N_CACHE-1:0][N_SLOT-1:0] slot_lookup_q;  // lookup launched for this slot
    logic [N_CACHE-1:0][N_SLOT-1:0] slot_rsp_q;  // this slot's tag answer arrives now
    logic [N_CACHE-1:0][N_SLOT-1:0] miss_seen_q;  // slot missed; waiting for FSM pickup
    logic [N_CACHE-1:0][N_SLOT-1:0] slot_miss_q;  // slot's miss taken by the FSM:
    // blocks younger queue entries until the miss completes (unstall)

    // Response queue (per cache): captured hit data, delivered to the CPU in
    // accept order. rvalid is a LEVEL held until rready pops the head —
    // protocol compliance, not a one-cycle lookup pulse. The element width
    // is the port's data width: 64 bits on I, 32 on D.
    logic [N_SLOT-1:0][yarv32_cache_pkg::IFETCH_DATA_W-1:0] rq_i_q;  // rq_i_q[0] is the head
    logic [N_SLOT-1:0][yarv32_cache_pkg::LSU_DATA_W-1:0] rq_d_q;  // rq_d_q[0] is the head
    logic [N_CACHE-1:0][N_SLOT-1:0] rq_blk_q;  // entry waits behind an older miss
    logic [N_CACHE-1:0][1:0] rq_cnt_q;  // entries in the queue (0..2)

    // Lookup compare context, registered at lookup launch. With back-to-back
    // I-port lookups the address split has already moved on to the next slot
    // when a tag answer arrives, so the compare runs against this registered
    // copy, not the live split. cmp_dw_sel_q is the I port's doubleword
    // index (addr[NBIT_OFFSET-1:3]); dcmp_word_sel_q is the D port's word
    // index (addr[NBIT_OFFSET-1:2]). dcmp_we_q is D-only — the I port has
    // no write side.
    logic [N_CACHE-1:0][TAG_FIELD_W-1:0] cmp_tag_q;
    logic [$clog2(DATA_WIDTH/yarv32_cache_pkg::IFETCH_DATA_W)-1:0] cmp_dw_sel_q;
    logic [$clog2(DATA_WIDTH/yarv32_cache_pkg::LSU_DATA_W)-1:0] dcmp_word_sel_q;
    logic dcmp_we_q;

    // Slot selection (per cache, always_comb — Verilator's V3Delayed chokes
    // on multiple calls of the same automatic function from a clocked
    // block). At most one slot is ever un-launched, so "first matching
    // slot" is unambiguous. The 0 defaults are unreachable whenever the
    // corresponding strobe (accept / lookup_go / rsp pulse / fsm latch) is
    // asserted.
    // Index widths are MINIMAL, never int. A 32-bit index into a packed
    // array asks the tool what the other four billion positions mean:
    // simulation clamps to the value in range, synthesis is free to build
    // something else, and the two stop agreeing. sv2v made that visible as
    // hundreds of "range select out of bounds" warnings on dmem_req.
    localparam int SLOT_IDX_W = $clog2(N_SLOT);

    logic [N_CACHE-1:0][SLOT_IDX_W-1:0]
        slot_free;  // first free slot (skid full only if accept low)
    logic [N_CACHE-1:0][SLOT_IDX_W-1:0] slot_lookup_sel;  // slot to launch the lookup for
    logic [N_CACHE-1:0][SLOT_IDX_W-1:0] slot_rsp_sel;  // slot the tag answer belongs to
    logic [N_CACHE-1:0][SLOT_IDX_W-1:0] slot_miss_sel;  // oldest slot the FSM will pick up
    logic [N_CACHE-1:0] slot_miss_wait;  // a slot awaits FSM pickup
    logic [N_CACHE-1:0][2:0] slot_outstanding;  // occupied slots + queue entries

    // -------------------------------------------------------------
    // Request target, decoded from the address at ACCEPT and latched per
    // slot. Decoding once, at accept, is what makes the control register
    // safe to write: a request already in flight keeps the target it was
    // accepted with, so flipping CACHE_BYPASS cannot re-route it halfway.
    //
    //   TGT_CACHE : SDRAM through the cache (tag lookup, refill, the lot)
    //   TGT_MEM   : SDRAM, cache bypassed — the miss FSM moves the
    //               doubleword straight to/from the device
    //   TGT_BOOT  : bootrom read (a write is a posted no-op: it is a ROM)
    //   TGT_CSR   : control register read/write
    // -------------------------------------------------------------
    localparam logic [1:0] TGT_CACHE = 2'd0;
    localparam logic [1:0] TGT_MEM = 2'd1;
    localparam logic [1:0] TGT_BOOT = 2'd2;
    localparam logic [1:0] TGT_CSR = 2'd3;

    logic [N_CACHE-1:0][N_SLOT-1:0][1:0] slot_tgt_q;  // target of each occupied slot
    logic [N_CACHE-1:0][1:0] acc_tgt;  // target of the request being offered now

    // The uncached targets share one rule: a slot holding one is the only
    // thing outstanding on its port (see the accept gating), so ordering
    // against cached responses needs no extra machinery — there is nothing
    // to order against.
    logic [N_CACHE-1:0] nc_busy;  // this port holds an uncached slot
    logic [N_CACHE-1:0][SLOT_IDX_W-1:0] nc_sel;  // which slot that is
    logic [N_CACHE-1:0][1:0] nc_tgt;  // its target
    logic [N_CACHE-1:0] nc_start;  // it has not been serviced yet
    logic [N_CACHE-1:0] nc_free;  // it completes this cycle: free the slot
    logic [N_CACHE-1:0] nc_push;  // ... and pushes a response
    logic [yarv32_cache_pkg::IFETCH_DATA_W-1:0] nc_push_data_i;  // I port's response
    logic [yarv32_cache_pkg::LSU_DATA_W-1:0] nc_push_data_d;  // D port's response
    logic [N_CACHE-1:0] nc_boot_go;  // bootrom read granted this cycle
    logic [N_CACHE-1:0] nc_byp_go;  // bypass slot handed to the miss FSM

    // Bootrom arbitration state: which port owns the read in flight.
    logic boot_busy_q;
    logic boot_owner_q;

    // Control register (CSR_W bits, see the package for the bit map).
    logic [CSR_W-1:0] csr_q;
    logic csr_wr;
    wire cache_bypass = csr_q[CSR_BIT_BYPASS];

    // Victim state for a missed slot, captured at its lookup pulse (the only
    // cycle the tag answers are guaranteed current — a later lookup on the
    // tag macro overwrites rdata_q). Round-robin victim selection per set:
    // prefer an invalid way, else the rr pointer, which advances on every
    // miss of that set.
    logic [N_CACHE-1:0][N_SETS-1:0] rr_q;
    logic [N_CACHE-1:0][N_SLOT-1:0][NBIT_WAY-1:0] victim_way_q;
    logic [N_CACHE-1:0][N_SLOT-1:0] victim_valid_q;
    logic [N_CACHE-1:0][N_SLOT-1:0] victim_dirty_q;
    logic [N_CACHE-1:0][N_SLOT-1:0][TAG_FIELD_W-1:0] victim_tag_q;

    logic [N_CACHE-1:0][NBIT_SET_IDX-1:0]
        rsp_set;  // set of the slot whose lookup answer is arriving
    logic [N_CACHE-1:0][NBIT_WAY-1:0] rsp_victim_way;  // victim way chosen for that answer

    // Miss-FSM macro access + unstall handshake with the skid/queue logic
    // above. All are driven by the FSM section below (or the store-hit path
    // next to it); declared here so the macro request muxes and the skid
    // always_ff can reference them.
    logic [N_CACHE-1:0] fsm_lookup_gate;  // FSM owns this cache's macros: hold lookups
    logic [N_CACHE-1:0] fsm_unstall;  // completed miss frees its slot (one cycle)
    logic [$clog2(N_SLOT)-1:0] fsm_unstall_slot;  // slot being unstalled
    logic [N_CACHE-1:0] fsm_rsp_push;  // completed miss was a load: push its response
    logic [yarv32_cache_pkg::IFETCH_DATA_W-1:0]
        fsm_rsp_data_i;  // I response from the refilled line
    logic [yarv32_cache_pkg::LSU_DATA_W-1:0] fsm_rsp_data_d;  // D response from the refilled line
    logic [NBIT_WAY-1:0] fsm_victim_way;  // victim way the FSM operates on
    way_req_t fsm_way_req;  // FSM request to the data macros
    tag_req_t fsm_tag_req;  // FSM request to the tag macros
    logic fsm_imem_access, fsm_dmem_access;  // FSM drives the data macros
    logic fsm_itag_write, fsm_dtag_write;  // FSM drives the tag macros
    logic [DATA_WIDTH-1:0] fsm_victim_line;  // victim line read back for WB
    logic [DATA_WIDTH-1:0] commit_line;  // refilled line (+ store merge)
    logic miss_is_store;  // the missed request is a store (write-allocate)
    logic dcache_store_hit;  // posted store hit: data+tag writes land now
    logic [NBIT_WAY-1:0] dhit_way;  // hit way of the store above
    way_req_t dstore_way_req;
    tag_req_t dstore_tag_req;

    always_comb begin
        for (int c = 0; c < N_CACHE; c++) begin
            if (!skid_valid_q[c][0]) slot_free[c] = 0;
            else if (!skid_valid_q[c][1]) slot_free[c] = 1;
            else slot_free[c] = 0;  // full: unreachable while accept high

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
            slot_outstanding[c] = 3'(skid_valid_q[c][0]) + 3'(skid_valid_q[c][1]) + 3'(rq_cnt_q[c]);

            // Context of the lookup answer arriving this cycle (if any):
            // its set and the victim way chosen for it. The tag macros'
            // rdata is only current while their rvalid pulses, so both are
            // consumed by the miss-pulse capture below, never sampled cold.
            rsp_set[c] = (c == 0) ? iskid_q[slot_rsp_sel[c]].addr[NBIT_OFFSET+:NBIT_SET_IDX] :
                dskid_q[slot_rsp_sel[c]].addr[NBIT_OFFSET+:NBIT_SET_IDX];
            rsp_victim_way[c] = NBIT_WAY'(rr_q[c][rsp_set[c]]);
            for (int i = N_WAY - 1; i >= 0; i--) begin
                if ((c == 0) ? !itag_rsp[i].rdata[0] : !dtag_rsp[i].rdata[0]) begin
                    rsp_victim_way[c] = NBIT_WAY'(i);
                end
            end
        end
    end

    // ===================================================================
    // Uncached targets: decode, bootrom arbitration, control register
    // ===================================================================

    function automatic logic [1:0] req_target(input logic [yarv32_cache_pkg::NATIVE_ADDR_W-1:0] a,
                                              input logic byp);
        case (yarv_region(
            a
        ))
            RGN_BOOT: req_target = TGT_BOOT;
            RGN_CSR:  req_target = TGT_CSR;
            default:  req_target = byp ? TGT_MEM : TGT_CACHE;
        endcase
    endfunction

    assign acc_tgt[0] = req_target(icache_req_i.addr, cache_bypass);
    assign acc_tgt[1] = req_target(dcache_req_i.addr, cache_bypass);

    // The uncached slot of each port (at most one, by the accept gating).
    always_comb begin
        for (int c = 0; c < N_CACHE; c++) begin
            nc_busy[c] = 1'b0;
            nc_sel[c]  = '0;
            for (int sl = N_SLOT - 1; sl >= 0; sl--) begin
                if (skid_valid_q[c][sl] && (slot_tgt_q[c][sl] != TGT_CACHE)) begin
                    nc_busy[c] = 1'b1;
                    nc_sel[c]  = SLOT_IDX_W'(sl);
                end
            end
            nc_tgt[c]   = slot_tgt_q[c][nc_sel[c]];
            // Not serviced yet. slot_lookup_q is reused as "started": the
            // bootrom read has been launched, or the bypass has been handed
            // to the miss FSM. Single-cycle targets (the register, a write
            // to the ROM) free the slot instead and never set it.
            nc_start[c] = nc_busy[c] && !slot_lookup_q[c][nc_sel[c]];
        end
    end

    // Control register: one cycle, no memory behind it. Only the D port
    // may write (the I port has no write side at all); both may read.
    logic [N_CACHE-1:0] nc_csr_done;
    assign nc_csr_done[0] = nc_start[0] && (nc_tgt[0] == TGT_CSR);
    assign nc_csr_done[1] = nc_start[1] && (nc_tgt[1] == TGT_CSR);
    assign csr_wr         = nc_csr_done[1] && dskid_q[nc_sel[1]].we && dskid_q[nc_sel[1]].wstrb[0];

    // Bootrom: read-only, so a D-port store to it retires with no side
    // effect (the I port cannot store at all).
    logic nc_boot_wr;
    assign nc_boot_wr = nc_start[1] && (nc_tgt[1] == TGT_BOOT) && dskid_q[nc_sel[1]].we;

    // Bootrom read: one macro, two ports. D wins ties, the same fixed
    // priority the miss FSM uses; the loser simply retries next cycle
    // (nc_start stays asserted until its own grant). Every I-port request
    // is a read, so no we term there.
    logic [N_CACHE-1:0] boot_rd_req;
    assign boot_rd_req[0] = nc_start[0] && (nc_tgt[0] == TGT_BOOT);
    assign boot_rd_req[1] = nc_start[1] && (nc_tgt[1] == TGT_BOOT) && !dskid_q[nc_sel[1]].we;

    assign nc_boot_go[1]  = boot_rd_req[1] && !boot_busy_q && bootr_rsp.wready;
    assign nc_boot_go[0]  = boot_rd_req[0] && !boot_busy_q && bootr_rsp.wready && !nc_boot_go[1];

    always_comb begin
        bootr_req        = '0;
        bootr_req.valid  = |nc_boot_go;
        bootr_req.we     = 1'b0;
        bootr_req.addr   = nc_boot_go[1] ? dskid_q[nc_sel[1]].addr : iskid_q[nc_sel[0]].addr;
        bootr_req.rready = 1'b1;
    end

    // The macro answers one cycle after the launch and holds rvalid until
    // rready, which is tied high here — so this is the completion cycle.
    wire boot_done = boot_busy_q && bootr_rsp.rvalid;
    logic [N_CACHE-1:0] boot_done_c;
    assign boot_done_c[0] = boot_done && (boot_owner_q == 1'b0);
    assign boot_done_c[1] = boot_done && (boot_owner_q == 1'b1);

    // Cache bypass: hand the slot to the miss FSM, which moves the
    // doubleword to/from the SDRAM without touching the cache arrays.
    // miss_seen_q is the same hand-off a real miss uses.
    assign nc_byp_go[0]   = nc_start[0] && (nc_tgt[0] == TGT_MEM);
    assign nc_byp_go[1]   = nc_start[1] && (nc_tgt[1] == TGT_MEM);

    // Completion: which uncached slots retire this cycle, and which of
    // them owe the CPU a response. The bypass path does NOT appear here —
    // it retires through the FSM's unstall, like a miss. A bootrom read
    // answers with the whole 64-bit macro word: the I port takes all of
    // it, the D port selects its half by the still-occupied slot's
    // addr[2] (the slot is freed only at this very nc_free edge, so the
    // address is current here).
    always_comb begin
        nc_free[0] = nc_csr_done[0] || boot_done_c[0];
        nc_free[1] = nc_csr_done[1] || nc_boot_wr || boot_done_c[1];
        nc_push[0] = boot_done_c[0] || nc_csr_done[0];
        nc_push[1] = boot_done_c[1] || (nc_csr_done[1] && !dskid_q[nc_sel[1]].we);
        nc_push_data_i = boot_done_c[0] ?
            bootr_rsp.rdata : {{(yarv32_cache_pkg::IFETCH_DATA_W - CSR_W) {1'b0}}, csr_q};
        nc_push_data_d = boot_done_c[1] ?
            (dskid_q[nc_sel[1]].addr[2] ? bootr_rsp.rdata[63:32] : bootr_rsp.rdata[31:0]) :
            {{(yarv32_cache_pkg::LSU_DATA_W - CSR_W) {1'b0}}, csr_q};
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            csr_q        <= CSR_RST_VAL;
            boot_busy_q  <= 1'b0;
            boot_owner_q <= 1'b0;
        end else begin
            if (csr_wr) csr_q <= dskid_q[nc_sel[1]].wdata[CSR_W-1:0];
            if (|nc_boot_go) begin
                boot_busy_q  <= 1'b1;
                boot_owner_q <= nc_boot_go[1];
            end else if (boot_done) begin
                boot_busy_q <= 1'b0;
            end
        end
    end

    // The address split runs off the skid slot being launched (see
    // iskid_q / dskid_q).
    ifetch_req_t cache_req_i;
    mem_req_t cache_req_d;

    assign cache_req_i = iskid_q[slot_lookup_sel[0]];
    assign cache_req_d = dskid_q[slot_lookup_sel[1]];

    // Lookup issue: exactly one tag+data macro lookup per accepted request
    // (slot_lookup_q gates relaunch while the CPU holds rready=1).
    logic [N_CACHE-1:0] cache_lookup_go;

    always_comb begin
        for (int c = 0; c < N_CACHE; c++) begin
            // Hold lookups while the miss FSM is accessing this cache's
            // data/tag macros (fsm_lookup_gate): a lookup launch would
            // clobber the victim-line read held in the macro's rdata_q, or
            // race the line/tag commit. Lookups on the OTHER cache and
            // accepts are unaffected — hits-under-miss resume during
            // the (long) refill states, which do not touch the macros.
            //
            // Only TGT_CACHE slots take this path: an uncached slot is
            // serviced by the bootrom/register/bypass logic instead, and a
            // tag lookup for it would be a lookup of an address that has no
            // tag (0x80_0000 aliases onto set 0 of the cache).
            cache_lookup_go[c] =
                ((skid_valid_q[c][0] && !slot_lookup_q[c][0] && (slot_tgt_q[c][0] == TGT_CACHE)) ||
                 (skid_valid_q[c][1] && !slot_lookup_q[c][1] && (slot_tgt_q[c][1] == TGT_CACHE))) &&
                !fsm_lookup_gate[c];
        end
    end

    // One response pulse per lookup: itag_rsp/dtag_rsp rvalid are identical
    // across ways (same broadcast lookup, same native_ram latency), so way 0
    // is a valid representative.
    logic [N_CACHE-1:0] cache_rsp_pulse;
    logic [N_CACHE-1:0] cache_hit_pulse;
    assign cache_rsp_pulse[0] = itag_rsp[0].rvalid;
    assign cache_rsp_pulse[1] = dtag_rsp[0].rvalid;
    assign cache_hit_pulse[0] = cache_rsp_pulse[0] && icache_hit;
    assign cache_hit_pulse[1] = cache_rsp_pulse[1] && dcache_hit;

    logic [N_CACHE-1:0][NBIT_OFFSET-1:0] offset;
    logic [N_CACHE-1:0][NBIT_SET_IDX-1:0] set_idx;
    logic [N_CACHE-1:0][NBIT_TAG-3:0] tag;
    // I port: doubleword index within a line (64-bit granularity),
    // selected by addr[NBIT_OFFSET-1:3]. D port: word index (32-bit
    // granularity), selected by addr[NBIT_OFFSET-1:2].
    logic [$clog2(DATA_WIDTH/yarv32_cache_pkg::IFETCH_DATA_W)-1:0] idw_sel;
    logic [$clog2(DATA_WIDTH/yarv32_cache_pkg::LSU_DATA_W)-1:0] dword_sel;

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

    // Bootrom, 2 KiB read-only, mapped at BOOTROM_BASE (0x80_0000).
    //
    // Both CPU ports reach it: the fetch side runs boot code out of it,
    // and the load side reads the payload the boot code copies into
    // SDRAM. The macro has one port, so the two are arbitrated (D wins
    // ties, same rule as the miss FSM) in the uncached-request section
    // below, which drives bootr_req and consumes bootr_rsp.
    native_ram #(
        .ADDR_W    (BOOTROM_ADDR_W),                   // 2 KiB
        .DATA_WIDTH(yarv32_cache_pkg::IFETCH_DATA_W),
        .READ_ONLY (1),
        .INIT_FILE (BOOTROM_FILE)
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
    //
    // The four TAG macros are RAM_STYLE("distributed"): 128 words of
    // TAG_DATA_W (16) bits is 2048 bits, and a Gowin BSRAM block holds
    // 18 kb, so each tag array spent a whole block on 11% of it — 4 of
    // the design's 36 blocks. In LUT-based SSRAM they cost none. The four
    // DATA macros stay in BSRAM: at DATA_WIDTH 256 they are 32 of the 36
    // blocks (BSRAM tops out at x32, so 8 blocks apiece for width alone)
    // and far too big for LUTs. Neither style resets its contents, so the
    // tag invalidation sweep below is needed either way.
    //
    // All eight are BYTE_WRITE(0): every write here commits a whole word.
    // Gowin BSRAM has no byte write enable, so a byte-writable 256-bit
    // line macro is built out of 32 byte-wide blocks instead of 8 —
    // 128 blocks for the four data macros alone, against 46 on the
    // GW2AR-18 (synthesis error RP0002). The only partial write in the
    // design is the D-cache store hit, and that path merges into the line
    // it has already read out (see dstore_way_req below).
    genvar w;
    generate
        for (w = 0; w < N_WAY; w++) begin : gen_way

            native_ram #(
                .ADDR_W    (WAY_ADDR_W),
                .DATA_WIDTH(DATA_WIDTH),
                .REQ_T     (way_req_t),
                .RSP_T     (way_rsp_t),
                .READ_ONLY (0),
                .BYTE_WRITE(0),           // whole-line writes only, see the store-hit merge
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
                .BYTE_WRITE(0),           // whole-line writes only, see the store-hit merge
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
                .BYTE_WRITE(0),             // whole-word writes only, see the store-hit merge
                .INIT_FILE (""),
                .RAM_STYLE ("distributed")  // LUT SSRAM: see the tag-macro note above
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
                .BYTE_WRITE(0),             // whole-word writes only, see the store-hit merge
                .INIT_FILE (""),
                .RAM_STYLE ("distributed")  // LUT SSRAM: see the tag-macro note above
            ) u_dtag (
                .clk_i    (clk_i),
                .rstn_i   (rstn_i),
                .mem_req_i(dtag_req[w]),
                .mem_rsp_o(dtag_rsp[w])
            );

        end
    endgenerate

    // ===================================================================
    // Tag invalidation sweep
    //
    // A cache may not trust the state its tag memory wakes up in. Nothing
    // in this design ever cleared the valid bits: simulation passed only
    // because an uninitialised array reads as zero there, and the board
    // was relying on whatever the tool happens to do with BSRAM contents
    // at configuration. In a 4-state gate-level run the same tags read X,
    // the hit/miss decision became X, and the X reached the skid slot's
    // valid bit and wedged the port — which is the failure the board
    // shows.
    //
    // So: after reset, walk every set and write valid=0 into every way of
    // both caches (the four tag macros are independent, so one set per
    // cycle covers all of them), and hold both ports' accept low until the
    // sweep is done. N_SETS cycles, once, at reset.
    // ===================================================================
    logic [NBIT_SET_IDX:0] tag_init_cnt_q;
    wire tag_init_done = tag_init_cnt_q[NBIT_SET_IDX];
    wire [NBIT_SET_IDX-1:0] tag_init_set = tag_init_cnt_q[NBIT_SET_IDX-1:0];

    always_ff @(posedge clk_i) begin
        if (!rstn_i) tag_init_cnt_q <= '0;
        else if (!tag_init_done) tag_init_cnt_q <= tag_init_cnt_q + 1'b1;
    end

    // SDRAM power-up hold: the controller's reset is released only after
    // SDRAM_INIT_US of stable clock (see the parameter). The counter is
    // sized from the same CLK_FREQ_MHZ that spaces the refreshes, so both
    // follow the real clock rate.
    localparam int INIT_WAIT_CYCLES = CLK_FREQ_MHZ * SDRAM_INIT_US;
    localparam int INIT_CNT_W = $clog2(INIT_WAIT_CYCLES + 1);

    logic [INIT_CNT_W-1:0] init_cnt_q;
    wire init_done = (init_cnt_q == INIT_CNT_W'(INIT_WAIT_CYCLES));
    wire sdrc_rstn = rstn_i && init_done;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) init_cnt_q <= '0;
        else if (!init_done) init_cnt_q <= init_cnt_q + 1'b1;
    end

    // SDRAM controller (src/ips/sdram-controller submodule, BSD; the
    // gw2ar-32bit branch adapts it to the GW2AR-18 embedded SDRAM: 32-bit
    // data, row/col/bank 11/8/2, CL=3, burst length 1 with auto-precharge
    // — one host word per transaction, refresh handled internally).
    sdram_controller #(
        .ROW_WIDTH    (11),
        .COL_WIDTH    (8),
        .BANK_WIDTH   (2),
        .DATA_WIDTH   (32),
        .CLK_FREQUENCY(CLK_FREQ_MHZ)
    ) u_sdram_cntrl (
        .wr_addr     (sdram_wr_addr),
        .wr_data     (sdram_wr_data),
        .wr_enable   (sdram_wr_en),
        .rd_addr     (sdram_rd_addr),
        .rd_data     (sdram_rd_data),
        .rd_ready    (sdram_rd_ready),
        .rd_enable   (sdram_rd_en),
        .busy        (sdram_busy),
        .rst_n       (sdrc_rstn),
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

    assign sdram_clk_o = sdram_clk_i;

    // SDRAM streaming engine. The miss FSM asks it for whole-line (or
    // single-word) transfers; every per-word handshake with the controller
    // lives inside it. See sdram_line_port.sv for the command contract --
    // in particular that cmd_wdata must hold until done.
    sdram_line_port #(
        .MEM_SIZE(MEM_SIZE),
        .LINE_W  (DATA_WIDTH)
    ) u_sdram_port (
        .clk_i           (clk_i),
        .rstn_i          (rstn_i),
        .cmd_valid_i     (eng_cmd_valid),
        .cmd_ready_o     (eng_cmd_ready),
        .cmd_we_i        (eng_cmd_we),
        .cmd_words_i     (eng_cmd_words),
        .cmd_addr_i      (eng_cmd_addr),
        .cmd_wdata_i     (eng_cmd_wdata),
        .done_o          (eng_done),
        .rdata_o         (eng_rdata),
        .sdram_rd_en_o   (sdram_rd_en),
        .sdram_rd_addr_o (sdram_rd_addr),
        .sdram_rd_data_i (sdram_rd_data),
        .sdram_rd_ready_i(sdram_rd_ready),
        .sdram_wr_en_o   (sdram_wr_en),
        .sdram_wr_addr_o (sdram_wr_addr),
        .sdram_wr_data_o (sdram_wr_data),
        .sdram_busy_i    (sdram_busy)
    );


    // ===================================================================
    // Cache controller logic (hit/miss, refill, write-back, arbitration)
    // ===================================================================

    // Address split per cache (classic bit-slice): addr = {tag, set, offset}.
    always_comb begin
        for (int c = 0; c < N_CACHE; c++) begin
            offset[c] = (c == 0) ? cache_req_i.addr[NBIT_OFFSET-1:0] :
                cache_req_d.addr[NBIT_OFFSET-1:0];
            set_idx[c] = (c == 0) ? cache_req_i.addr[NBIT_OFFSET+:NBIT_SET_IDX] :
                cache_req_d.addr[NBIT_OFFSET+:NBIT_SET_IDX];
            tag[c] = (c == 0) ? cache_req_i.addr[MEM_SIZE-1-:TAG_FIELD_W] :
                cache_req_d.addr[MEM_SIZE-1-:TAG_FIELD_W];
        end
        idw_sel   = offset[0][NBIT_OFFSET-1:3];
        dword_sel = offset[1][NBIT_OFFSET-1:2];
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
                {(yarv32_cache_pkg::NATIVE_ADDR_W - NBIT_SET_IDX - TAG_BYTES_W) {1'b0}},
                set_idx[0],
                {TAG_BYTES_W{1'b0}}
            };
            itag_req[i].rready = 1'b1;

            dtag_req[i] = '0;
            dtag_req[i].valid = cache_lookup_go[1];
            dtag_req[i].we = 1'b0;
            dtag_req[i].addr = {
                {(yarv32_cache_pkg::NATIVE_ADDR_W - NBIT_SET_IDX - TAG_BYTES_W) {1'b0}},
                set_idx[1],
                {TAG_BYTES_W{1'b0}}
            };
            dtag_req[i].rready = 1'b1;
        end

        // Invalidation sweep owns the tag macros until it is done. It runs
        // before any request can be accepted (accept is low), so nothing
        // else is driving them here.
        if (!tag_init_done) begin
            for (int i = 0; i < N_WAY; i++) begin
                itag_req[i] = '0;
                itag_req[i].valid = 1'b1;
                itag_req[i].we = 1'b1;
                itag_req[i].addr = {
                    {(yarv32_cache_pkg::NATIVE_ADDR_W - NBIT_SET_IDX - TAG_BYTES_W) {1'b0}},
                    tag_init_set,
                    {TAG_BYTES_W{1'b0}}
                };
                itag_req[i].wdata = '0;  // valid = 0, dirty = 0, tag = 0
                itag_req[i].wstrb = {(TAG_DATA_W / 8) {1'b1}};
                itag_req[i].rready = 1'b1;

                dtag_req[i] = itag_req[i];
            end
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
            imem_req[i].addr   = cache_req_i.addr;
            imem_req[i].rready = 1'b1;

            dmem_req[i]        = '0;
            dmem_req[i].valid  = cache_lookup_go[1];
            dmem_req[i].we     = 1'b0;  // lookup only; writes come from the store path / FSM
            dmem_req[i].wstrb  = '0;
            dmem_req[i].addr   = cache_req_d.addr;
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

    // Doubleword (I) / word (D) selected out of the hit line
    // (cmp_dw_sel_q / dcmp_word_sel_q are the launch-registered copies of
    // addr[NBIT_OFFSET-1:3] / addr[NBIT_OFFSET-1:2]).
    logic [yarv32_cache_pkg::IFETCH_DATA_W-1:0] icache_push_data;
    logic [yarv32_cache_pkg::LSU_DATA_W-1:0] dcache_push_data;
    assign icache_push_data = icache_line[cmp_dw_sel_q*64+:64];
    assign dcache_push_data = dcache_line[dcmp_word_sel_q*32+:32];

    // -------------------------------------------------------------
    // Skid + response queue state (per cache):
    //   accept    : raw CPU request latched into the first free slot
    //   lookup_go : launches the one tag+data lookup for that slot and
    //               registers the compare context (cmp_tag_q /
    //               cmp_dw_sel_q / dcmp_word_sel_q / dcmp_we_q) off the
    //               launching slot's split
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
    logic [N_CACHE-1:0] cache_accept;
    assign cache_accept[0] = icache_req_i.valid && icache_rsp_o.ready;
    assign cache_accept[1] = dcache_req_i.wvalid && dcache_rsp_o.wready;

    // CPU consumed the queue head.
    logic [N_CACHE-1:0] cache_pop;
    assign cache_pop[0] = icache_req_i.rready && icache_rsp_o.rvalid;
    assign cache_pop[1] = dcache_req_i.rready && dcache_rsp_o.rvalid;

    // Queue push: the tag answer was a load hit, or an uncached read
    // (bootrom / control register) completed. The two can never coincide —
    // an uncached slot is alone on its port — so one queue port serves both.
    // The I port has no we: every hit pushes.
    logic [N_CACHE-1:0] cache_push;
    assign cache_push[0] = (cache_rsp_pulse[0] && cache_hit_pulse[0]) || nc_push[0];
    assign cache_push[1] = (cache_rsp_pulse[1] && cache_hit_pulse[1] && !dcmp_we_q) || nc_push[1];

    logic [yarv32_cache_pkg::IFETCH_DATA_W-1:0] cache_push_data_i;
    logic [yarv32_cache_pkg::LSU_DATA_W-1:0] cache_push_data_d;
    assign cache_push_data_i = nc_push[0] ? nc_push_data_i : icache_push_data;
    assign cache_push_data_d = nc_push[1] ? nc_push_data_d : dcache_push_data;

    // An unresolved miss (pending pickup or owned by the FSM) older than
    // the entry being pushed blocks that entry: responses must be delivered
    // in accept order (the fetch unit's instruction buffer relies on it).
    logic [N_CACHE-1:0] older_miss;
    assign older_miss[0] = (|slot_miss_q[0]) || slot_miss_wait[0];
    assign older_miss[1] = (|slot_miss_q[1]) || slot_miss_wait[1];

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            for (int c = 0; c < N_CACHE; c++) begin
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
                slot_tgt_q[c][0]    <= TGT_CACHE;
                slot_tgt_q[c][1]    <= TGT_CACHE;
                rq_blk_q[c][0]      <= 1'b0;
                rq_blk_q[c][1]      <= 1'b0;
                rq_cnt_q[c]         <= '0;
                cmp_tag_q[c]        <= '0;
            end
            iskid_q[0]      <= '0;
            iskid_q[1]      <= '0;
            dskid_q[0]      <= '0;
            dskid_q[1]      <= '0;
            rq_i_q[0]       <= '0;
            rq_i_q[1]       <= '0;
            rq_d_q[0]       <= '0;
            rq_d_q[1]       <= '0;
            cmp_dw_sel_q    <= '0;
            dcmp_word_sel_q <= '0;
            dcmp_we_q       <= 1'b0;
            for (int c = 0; c < N_CACHE; c++) begin
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
                // Accept: fill the first free slot (accept guarantees one).
                // Whole-struct copies: the skid split keeps each port's
                // request in its own typed array, so the copy stays a
                // packed-vector assignment of the same expansion.
                if (cache_accept[c]) begin
                    if (c == 0) iskid_q[slot_free[c]] <= icache_req_i;
                    else dskid_q[slot_free[c]] <= dcache_req_i;
                    skid_valid_q[c][slot_free[c]]  <= 1'b1;
                    slot_lookup_q[c][slot_free[c]] <= 1'b0;
                    slot_rsp_q[c][slot_free[c]]    <= 1'b0;
                    miss_seen_q[c][slot_free[c]]   <= 1'b0;
                    slot_miss_q[c][slot_free[c]]   <= 1'b0;
                    // Target decoded from the address (and the bypass bit
                    // as it stands NOW) and frozen for the slot's lifetime.
                    slot_tgt_q[c][slot_free[c]]    <= acc_tgt[c];
                end

                // Uncached slot started: the bootrom read has been launched,
                // or the bypass request handed to the miss FSM. Reuses
                // slot_lookup_q as the "already started" flag, so the
                // service logic fires exactly once per request, the same
                // property cache_lookup_go gives a cached one.
                if (nc_boot_go[c] || nc_byp_go[c]) slot_lookup_q[c][nc_sel[c]] <= 1'b1;
                if (nc_byp_go[c]) miss_seen_q[c][nc_sel[c]] <= 1'b1;

                // Uncached slot retired (register access, or a write to the
                // ROM, or the bootrom read answered). The bypass path does
                // not come through here: it retires at the FSM's unstall.
                if (nc_free[c]) skid_valid_q[c][nc_sel[c]] <= 1'b0;

                // Lookup launch for the (single) un-launched slot.
                if (cache_lookup_go[c]) begin
                    slot_lookup_q[c][slot_lookup_sel[c]] <= 1'b1;
                    slot_rsp_q[c][slot_lookup_sel[c]]    <= 1'b1;
                    cmp_tag_q[c]                         <= tag[c];
                    if (c == 0) cmp_dw_sel_q <= idw_sel;
                    else begin
                        dcmp_word_sel_q <= dword_sel;
                        dcmp_we_q       <= cache_req_d.we;
                    end
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

                // FSM pickup of the oldest missed slot.
                if (cache_fsm_latch[c]) begin
                    miss_seen_q[c][slot_miss_sel[c]] <= 1'b0;
                    slot_miss_q[c][slot_miss_sel[c]] <= 1'b1;
                end
            end

            // Response queue, unrolled per port (the element widths differ:
            // 64-bit I data, 32-bit D data). Identical control logic either
            // way — the unroll is textual.
            //
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

            // --- I port (64-bit entries) ---
            if (fsm_unstall[0]) begin
                skid_valid_q[0][fsm_unstall_slot] <= 1'b0;
                slot_miss_q[0][fsm_unstall_slot]  <= 1'b0;
                rq_blk_q[0][0]                    <= 1'b0;
                rq_blk_q[0][1]                    <= 1'b0;
                if (fsm_rsp_push[0]) begin
                    if (cache_pop[0]) begin
                        // Unblocked head consumed this cycle: take its place.
                        rq_i_q[0] <= fsm_rsp_data_i;
                    end else if (rq_cnt_q[0] == 2'd0) begin
                        rq_cnt_q[0] <= rq_cnt_q[0] + 2'd1;
                        rq_i_q[0]   <= fsm_rsp_data_i;
                    end else if (!rq_blk_q[0][0]) begin
                        // Older entry at the head: miss response goes behind it.
                        rq_cnt_q[0] <= rq_cnt_q[0] + 2'd1;
                        rq_i_q[1]   <= fsm_rsp_data_i;
                    end else begin
                        // Younger entry latched blocked behind the miss:
                        // the (older) miss response goes in front of it.
                        rq_cnt_q[0] <= rq_cnt_q[0] + 2'd1;
                        rq_i_q[1]   <= rq_i_q[0];
                        rq_i_q[0]   <= fsm_rsp_data_i;
                    end
                end
            end else if (cache_push[0] && cache_pop[0]) begin
                rq_i_q[0]      <= cache_push_data_i;
                rq_blk_q[0][0] <= older_miss[0];
            end else if (cache_push[0]) begin
                rq_cnt_q[0]                            <= rq_cnt_q[0] + 2'd1;
                rq_i_q[(rq_cnt_q[0]==2'd0)?0 : 1]      <= cache_push_data_i;
                rq_blk_q[0][(rq_cnt_q[0]==2'd0)?0 : 1] <= older_miss[0];
            end else if (cache_pop[0]) begin
                rq_cnt_q[0]    <= rq_cnt_q[0] - 2'd1;
                rq_i_q[0]      <= rq_i_q[1];
                rq_blk_q[0][0] <= rq_blk_q[0][1];
            end

            // --- D port (32-bit entries) ---
            if (fsm_unstall[1]) begin
                skid_valid_q[1][fsm_unstall_slot] <= 1'b0;
                slot_miss_q[1][fsm_unstall_slot]  <= 1'b0;
                rq_blk_q[1][0]                    <= 1'b0;
                rq_blk_q[1][1]                    <= 1'b0;
                if (fsm_rsp_push[1]) begin
                    if (cache_pop[1]) begin
                        rq_d_q[0] <= fsm_rsp_data_d;
                    end else if (rq_cnt_q[1] == 2'd0) begin
                        rq_cnt_q[1] <= rq_cnt_q[1] + 2'd1;
                        rq_d_q[0]   <= fsm_rsp_data_d;
                    end else if (!rq_blk_q[1][0]) begin
                        rq_cnt_q[1] <= rq_cnt_q[1] + 2'd1;
                        rq_d_q[1]   <= fsm_rsp_data_d;
                    end else begin
                        rq_cnt_q[1] <= rq_cnt_q[1] + 2'd1;
                        rq_d_q[1]   <= rq_d_q[0];
                        rq_d_q[0]   <= fsm_rsp_data_d;
                    end
                end
            end else if (cache_push[1] && cache_pop[1]) begin
                rq_d_q[0]      <= cache_push_data_d;
                rq_blk_q[1][0] <= older_miss[1];
            end else if (cache_push[1]) begin
                rq_cnt_q[1]                            <= rq_cnt_q[1] + 2'd1;
                rq_d_q[(rq_cnt_q[1]==2'd0)?0 : 1]      <= cache_push_data_d;
                rq_blk_q[1][(rq_cnt_q[1]==2'd0)?0 : 1] <= older_miss[1];
            end else if (cache_pop[1]) begin
                rq_cnt_q[1]    <= rq_cnt_q[1] - 2'd1;
                rq_d_q[0]      <= rq_d_q[1];
                rq_blk_q[1][0] <= rq_blk_q[1][1];
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
    // SDRAM access model: the controller moves one 32-bit word per
    // transaction, so a refill is BURST_LEN word reads and a writeback
    // BURST_LEN word writes. Those per-word handshakes are NOT here — they
    // are sdram_line_port's job (see its header). This FSM issues one
    // command per phase and waits for eng_done, which is what keeps it
    // readable as the policy it is: arbitrate, pick a victim, write it
    // back, refill, commit, unstall.

    localparam int BURST_LEN = DATA_WIDTH / 32;  // 32-bit SDRAM data bus

    typedef enum logic [3:0] {
        S_IDLE,
        S_ARBITRATE,
        S_WB_READ,  // read the victim line out of its data macro
        S_WB_XFER,  // stream the victim line out; skipped if victim not dirty
        S_REFILL_XFER,  // stream the missing line in
        S_UPDATE_TAG,  // commit line + tag into the victim way
        S_UNSTALL,  // free the missed slot, deliver the response
        // Cache-bypass path (TGT_MEM): the CPU datum straight to/from the
        // device (an I doubleword = two 32-bit SDRAM words, a D word =
        // one), no cache array touched. A store is a read-modify-write
        // unless the store strobes all four of its bytes — the controller
        // drives dqm itself, so a partial word cannot be masked at the
        // pins.
        S_BP_READ,
        S_BP_WRITE
    } fsm_state_e;

    fsm_state_e state_q, state_d;

    assign dbg_state_o = state_q;

    // D-cache event counters (see dbg_cnt_o). Saturating: a stuck port is
    // identified by the first count that stops advancing, so wrapping
    // would destroy exactly the information wanted.
    // syn_preserve / syn_keep: these are probes, and a probe the optimiser
    // is allowed to fold into a constant reports the optimiser's opinion
    // instead of the hardware's behaviour. On the board every one of them
    // read zero while the state they count said the events had happened,
    // so they are pinned here and the next build says whether the freeze
    // is in the design or in what synthesis did to it.
    (* syn_preserve = 1 *)
    (* syn_keep = 1 *)
    logic [3:0] cnt_lookup_q, cnt_pulse_q, cnt_miss_q, cnt_unstall_q, cnt_acc_q;
    (* syn_preserve = 1 *) (* syn_keep = 1 *)
    logic [24:0] tick_q;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            cnt_lookup_q  <= '0;
            cnt_pulse_q   <= '0;
            cnt_miss_q    <= '0;
            cnt_unstall_q <= '0;
            cnt_acc_q     <= '0;
            tick_q        <= '0;
        end else begin
            tick_q <= tick_q + 1'b1;
            if (cache_accept[1] && !(&cnt_acc_q)) cnt_acc_q <= cnt_acc_q + 1'b1;
            if (cache_lookup_go[1] && !(&cnt_lookup_q)) cnt_lookup_q <= cnt_lookup_q + 1'b1;
            if (cache_rsp_pulse[1] && !(&cnt_pulse_q)) cnt_pulse_q <= cnt_pulse_q + 1'b1;
            if ((state_q == S_IDLE) && miss_pending && miss_sel && !(&cnt_miss_q))
                cnt_miss_q <= cnt_miss_q + 1'b1;
            if (fsm_unstall[1] && !(&cnt_unstall_q)) cnt_unstall_q <= cnt_unstall_q + 1'b1;
        end
    end

    assign dbg_cnt_o = {cnt_unstall_q, cnt_miss_q, cnt_pulse_q, cnt_lookup_q};
    assign dbg_acc_o = cnt_acc_q;
    // Bits chosen so the field changes between two report lines at both
    // rates in use: every 4096 clocks is ~82 us on the board and ~41 us in
    // simulation, both far shorter than a report period.
    // Bits 15:12 tick every 4096 clocks. NOT a multiple of the reporter's
    // period, which is what the first version got wrong: it exported
    // tick_q[15:12] while the reporter sampled every 2**24 clocks, an exact
    // multiple of that field's own period, so every sample landed on the
    // same phase and the field read constant. A constant probe reads
    // exactly like a dead clock, and it cost three board round-trips.
    // 5 bits down from the sample period, offset by a prime-ish shift:
    assign dbg_tick_o = {tick_q[20], tick_q[17], tick_q[14], tick_q[11]};
    assign dbg_hb_o = tick_q[24];
    assign dbg_go_o = {
        cache_lookup_go[1], fsm_lookup_gate[1], dtag_req[0].valid, dtag_rsp[0].wready
    };
    assign dbg_rsp_o = {
        dtag_rsp[0].rvalid, dmem_rsp_d[0].rvalid, slot_rsp_q[1][0], slot_rsp_q[1][1]
    };
    assign dbg_dport_o = {
        skid_valid_q[1][0], slot_lookup_q[1][0], miss_seen_q[1][0], rq_cnt_q[1] != 2'd0
    };

    logic req_sel_q, req_sel_d;  // 0 = icache, 1 = dcache
    logic [yarv32_cache_pkg::NATIVE_ADDR_W-1:0] miss_addr_q, miss_addr_d;
    logic [$clog2(N_SLOT)-1:0] miss_slot_q, miss_slot_d;  // skid slot the FSM owns
    logic byp_q, byp_d;  // the latched slot is a cache-bypass access

    logic miss_pending;
    logic miss_sel;  // 0 = icache, 1 = dcache (the entry the FSM will pick up)
    logic [N_CACHE-1:0] cache_fsm_latch;

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
            miss_addr_q <= '0;
            miss_slot_q <= '0;
            byp_q       <= 1'b0;
        end else begin
            state_q     <= state_d;
            req_sel_q   <= req_sel_d;
            miss_addr_q <= miss_addr_d;
            miss_slot_q <= miss_slot_d;
            byp_q       <= byp_d;
        end
    end

    // Line-aligned byte addresses: writeback targets the VICTIM's line
    // {victim_tag, set, offset 0} — NOT the missing address (that would
    // overwrite the missing line's own SDRAM location with victim data);
    // refill reads the missing line itself. The controller's host address
    // is the 32-bit word index {bank, row, col} = byte_addr[22:2], which is
    // what the engine is given as the command's FIRST word; it walks the
    // rest of the line from there.
    logic [22:0] wb_byte_addr, refill_byte_addr;
    assign wb_byte_addr = {
        victim_tag_q[req_sel_q][miss_slot_q],
        miss_addr_q[NBIT_OFFSET+:NBIT_SET_IDX],
        {NBIT_OFFSET{1'b0}}
    };
    assign refill_byte_addr = {miss_addr_q[MEM_SIZE-1:NBIT_OFFSET], {NBIT_OFFSET{1'b0}}};

    // Cache-bypass datapath. The owning port sets the transfer length
    // (req_sel_q, latched in S_IDLE): an I bypass moves a 64-bit
    // doubleword as two consecutive 32-bit SDRAM words, a D bypass moves
    // one. The engine walks the words itself, so what it needs here is the
    // FIRST word address — which for the I case is the doubleword base,
    // hence the forced zero in the low bit. Only the D port can store (the
    // I port is read-only), so the store datapath below reads dskid_q
    // unconditionally — gated by req_sel_q so an I bypass sees zeros,
    // never stale D state.
    wire [3:0] bp_words = req_sel_q ? 4'd1 : 4'd2;

    wire [MEM_SIZE-1:2]
        bp_base_addr = req_sel_q ? miss_addr_q[MEM_SIZE-1:2] : {miss_addr_q[MEM_SIZE-1:3], 1'b0};

    wire [3:0] bp_strb = req_sel_q ? dskid_q[miss_slot_q].wstrb : 4'h0;
    wire [31:0] bp_wdata = req_sel_q ? dskid_q[miss_slot_q].wdata : 32'h0;

    // A store that strobes the whole word needs no read first; a partial
    // one is merged into the word just read back (the controller's dqm is
    // not under this FSM's control, so masking at the pins is not an
    // option).
    wire bp_full_word = &bp_strb;
    wire bp_skip_read = miss_is_store && bp_full_word;

    logic [31:0] bp_wr_data;

    always_comb begin
        bp_wr_data = eng_rdata[31:0];
        for (int b = 0; b < 4; b++) begin
            if (bp_strb[b]) bp_wr_data[b*8+:8] = bp_wdata[b*8+:8];
        end
    end

    // Engine write data. Word 0 carries a bypass store's merged word; all
    // the higher words are only ever consumed by a line writeback, so the
    // victim line drives them unconditionally rather than through a
    // DATA_WIDTH-wide mux that would select between a line and 224 bits of
    // zero.
    always_comb begin
        eng_cmd_wdata = fsm_victim_line;
        if (byp_q) eng_cmd_wdata[31:0] = bp_wr_data;
    end

    always_comb begin
        // defaults: hold state / datapath
        state_d       = state_q;
        req_sel_d     = req_sel_q;
        miss_addr_d   = miss_addr_q;
        miss_slot_d   = miss_slot_q;
        byp_d         = byp_q;

        // Engine command defaults. In the transfer states below cmd_valid
        // is simply tied to the engine's own ready: that is the whole
        // handshake, because the engine keeps ready low through the cycle
        // it pulses done, so a command cannot be re-issued in the cycle it
        // is seen to finish.
        eng_cmd_valid = 1'b0;
        eng_cmd_we    = 1'b0;
        eng_cmd_words = 4'd1;
        eng_cmd_addr  = bp_base_addr;

        unique case (state_q)

            S_IDLE: begin
                if (miss_pending) begin
                    // Fixed priority: dcache wins ties (avoids stalling
                    // stores). cache_fsm_latch (above) marks the picked-up
                    // slot slot_miss_q; the FSM owns it until the miss
                    // completes.
                    req_sel_d = miss_sel;
                    miss_addr_d = miss_sel ? dskid_q[slot_miss_sel[miss_sel]].addr :
                        iskid_q[slot_miss_sel[miss_sel]].addr;
                    miss_slot_d = $clog2(N_SLOT)'(slot_miss_sel[miss_sel]);
                    // A bypass slot arrives through the same hand-off as a
                    // miss (miss_seen_q); this is what tells the two apart
                    // for the rest of the transfer.
                    byp_d = (slot_tgt_q[miss_sel][slot_miss_sel[miss_sel]] == TGT_MEM);
                    state_d = S_ARBITRATE;
                end
            end

            S_ARBITRATE: begin
                // Victim way/tag/dirty were captured at the miss's lookup
                // pulse (victim_*_q, per slot — see the skid block). Only a
                // valid AND dirty victim needs its line written back before
                // the refill overwrites the way.
                //
                // A bypass has no victim (no tag lookup ever ran for it,
                // so victim_*_q hold whatever the previous miss left) and
                // no line: straight to the word transfer.
                if (byp_q) state_d = S_BP_READ;
                else
                    state_d = (victim_valid_q[req_sel_q][miss_slot_q] &&
                               victim_dirty_q[req_sel_q][miss_slot_q]) ? S_WB_READ : S_REFILL_XFER;
            end

            S_WB_READ: begin
                // The data-macro read of the victim line is driven by the
                // FSM request mux (fsm_way_req): it launches this cycle and
                // the data is valid from S_WB_XFER on, held in the macro's
                // rdata_q (lookups are gated for the whole writeback, so no
                // other read can clobber it — which is also what lets the
                // engine read its write data straight off that output).
                state_d = S_WB_XFER;
            end

            S_WB_XFER: begin
                // The victim's own line address: {victim_tag, set, 0}.
                eng_cmd_valid = eng_cmd_ready;
                eng_cmd_we    = 1'b1;
                eng_cmd_words = 4'(BURST_LEN);
                eng_cmd_addr  = wb_byte_addr[MEM_SIZE-1:2];
                if (eng_done) state_d = S_REFILL_XFER;
            end

            S_REFILL_XFER: begin
                // The missing line itself; the words land in eng_rdata.
                eng_cmd_valid = eng_cmd_ready;
                eng_cmd_words = 4'(BURST_LEN);
                eng_cmd_addr  = refill_byte_addr[MEM_SIZE-1:2];
                if (eng_done) state_d = S_UPDATE_TAG;
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

            // ---- cache-bypass transfer (byp_q) ----

            S_BP_READ: begin
                // A full-word store overwrites everything the read would
                // have returned, so skip it. Otherwise fetch the whole
                // access in one command: one word for a D bypass, the two
                // words of the doubleword for an I one.
                if (bp_skip_read) begin
                    state_d = S_BP_WRITE;
                end else begin
                    eng_cmd_valid = eng_cmd_ready;
                    eng_cmd_words = bp_words;
                    if (eng_done) state_d = miss_is_store ? S_BP_WRITE : S_UNSTALL;
                end
            end

            S_BP_WRITE: begin
                // Always a single word: only the D port can store, and a D
                // bypass is one word wide. (The read-modify-write merge is
                // in bp_wr_data, which eng_cmd_wdata places at word 0.)
                eng_cmd_valid = eng_cmd_ready;
                eng_cmd_we    = 1'b1;
                eng_cmd_words = 4'd1;
                if (eng_done) state_d = S_UNSTALL;
            end

            default: state_d = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------
    // FSM datapath muxes (declared with the signals above, driven here
    // after the FSM state they depend on).
    // -------------------------------------------------------------

    // Victim line as read back in S_WB_READ: held in the victim way's
    // rdata_q through S_WB_XFER (lookups are gated, so no other read can
    // overwrite it). This is the engine's write data, and holding it for
    // the whole transfer is exactly the contract sdram_line_port states.
    assign fsm_victim_line = (req_sel_q == 1'b0) ? imem_rsp_d[fsm_victim_way].rdata :
        dmem_rsp_d[fsm_victim_way].rdata;

    // The missed request is a store: write-allocate — the line is committed
    // with the store already merged, so it lands dirty. D-only (the I port
    // has no write side): the merge targets the 32-bit word the store
    // addresses, miss_addr_q[NBIT_OFFSET-1:2].
    assign miss_is_store = req_sel_q && dskid_q[miss_slot_q].we;

    always_comb begin
        commit_line = eng_rdata;
        if (miss_is_store) begin
            for (int b = 0; b < yarv32_cache_pkg::LSU_STRB_W; b++) begin
                if (dskid_q[miss_slot_q].wstrb[b]) begin
                    commit_line[miss_addr_q[NBIT_OFFSET-1:2]*32+b*8+:8] =
                        dskid_q[miss_slot_q].wdata[b*8+:8];
                end
            end
        end
    end

    // FSM requests to the data/tag macros of the cache being serviced
    // (req_sel_q). Lookups on that cache are gated while these are active,
    // so the muxes in the macro request blocks never arbitrate two drivers.
    always_comb begin
        fsm_victim_way  = victim_way_q[req_sel_q][miss_slot_q];
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
                    {(yarv32_cache_pkg::NATIVE_ADDR_W - MEM_SIZE) {1'b0}},
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
                fsm_way_req.addr = {
                    {(yarv32_cache_pkg::NATIVE_ADDR_W - MEM_SIZE) {1'b0}}, miss_addr_q[MEM_SIZE-1:0]
                };
                fsm_way_req.wdata = commit_line;
                fsm_way_req.wstrb = {(DATA_WIDTH / 8) {1'b1}};
                fsm_way_req.rready = 1'b1;

                fsm_tag_req.valid = 1'b1;
                fsm_tag_req.we = 1'b1;
                // Same set-index shift as the lookup requests.
                fsm_tag_req.addr = {
                    {(yarv32_cache_pkg::NATIVE_ADDR_W - NBIT_SET_IDX - TAG_BYTES_W) {1'b0}},
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
    // touches its macros: S_WB_READ and S_WB_XFER hold the victim line in
    // the data macro's rdata_q (the engine streams its write data straight
    // off that output), S_UPDATE_TAG commits the line+tag writes.
    // S_REFILL_XFER leaves the macros alone, so hits resume during the long
    // refill phase.
    logic fsm_macro_state;
    assign fsm_macro_state = (state_q == S_WB_READ) || (state_q == S_WB_XFER) ||
        (state_q == S_UPDATE_TAG);
    assign fsm_lookup_gate[0] = fsm_macro_state && (req_sel_q == 1'b0);
    assign fsm_lookup_gate[1] = fsm_macro_state && (req_sel_q == 1'b1);

    // Unstall (S_UNSTALL cycle): free the missed slot; a load miss pushes
    // its response — the refilled line's doubleword (I) / word (D) — in
    // accept order. Every I unstall pushes (the I port has no stores).
    assign fsm_unstall_slot = miss_slot_q;
    assign fsm_unstall[0] = (state_q == S_UNSTALL) && (req_sel_q == 1'b0);
    assign fsm_unstall[1] = (state_q == S_UNSTALL) && (req_sel_q == 1'b1);
    assign fsm_rsp_push[0] = fsm_unstall[0];
    assign fsm_rsp_push[1] = fsm_unstall[1] && !dskid_q[miss_slot_q].we;
    // A refill answers out of the line the engine just assembled; a bypass
    // answers with the word(s) it fetched, which sit at the bottom of that
    // same buffer.
    assign fsm_rsp_data_i = byp_q ? eng_rdata[yarv32_cache_pkg::IFETCH_DATA_W-1:0] :
        eng_rdata[miss_addr_q[NBIT_OFFSET-1:3]*64+:64];
    assign fsm_rsp_data_d = byp_q ? eng_rdata[yarv32_cache_pkg::LSU_DATA_W-1:0] :
        eng_rdata[miss_addr_q[NBIT_OFFSET-1:2]*32+:32];

    // -------------------------------------------------------------
    // D-cache store hit (posted). The data-macro write into the hit way and
    // the dirty-bit tag write fire the same cycle the tag answer pulses.
    //
    // The write is a READ-MODIFY-WRITE of the whole line, not a
    // byte-strobed one: the data macros are BYTE_WRITE(0) (byte enables
    // cost 4x the BSRAM blocks on this device, see the macro
    // instantiation above). The line being modified is already on the
    // macro's registered output this very cycle — dcache_line, the hit
    // way's rdata — so merging the stored bytes into it costs no extra
    // cycle and no extra port. Only the bytes the store strobes at its
    // word (dcmp_word_sel_q) change; every other byte is written back
    // with the value just read.
    // -------------------------------------------------------------
    assign dcache_store_hit = cache_rsp_pulse[1] && cache_hit_pulse[1] && dcmp_we_q;

    always_comb begin
        dhit_way = '0;
        for (int i = N_WAY - 1; i >= 0; i--) begin
            if (dcache_way_hit[i]) dhit_way = NBIT_WAY'(i);
        end
    end

    always_comb begin
        dstore_way_req       = '0;
        dstore_way_req.valid = dcache_store_hit;
        dstore_way_req.we    = 1'b1;
        dstore_way_req.addr  = dskid_q[slot_rsp_sel[1]].addr;
        // Start from the line as it stands in the hit way, then overwrite
        // only the strobed bytes of the addressed word.
        dstore_way_req.wdata = dcache_line;
        for (int b = 0; b < yarv32_cache_pkg::LSU_STRB_W; b++) begin
            if (dskid_q[slot_rsp_sel[1]].wstrb[b]) begin
                dstore_way_req.wdata[dcmp_word_sel_q*32+b*8+:8] =
                    dskid_q[slot_rsp_sel[1]].wdata[b*8+:8];
            end
        end
        dstore_way_req.wstrb = {(DATA_WIDTH / 8) {1'b1}};
        dstore_way_req.rready = 1'b1;

        dstore_tag_req = '0;
        dstore_tag_req.valid = dcache_store_hit;
        dstore_tag_req.we = 1'b1;
        dstore_tag_req.addr = {
            {(yarv32_cache_pkg::NATIVE_ADDR_W - NBIT_SET_IDX - TAG_BYTES_W) {1'b0}},
            dskid_q[slot_rsp_sel[1]].addr[NBIT_OFFSET+:NBIT_SET_IDX],
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
    //   The port accepts while outstanding (occupied slots + unconsumed
    //   entries) is below the per-port limit: 2 for the I-port's 2
    //   outstanding reads, 1 for the single-outstanding D-port. Hits are
    //   served while the miss FSM is mid-transit; only unresolved-miss
    //   slots gate delivery.
    // -------------------------------------------------------------
    //   An UNCACHED request (bootrom, control register, cache bypass) is
    //   accepted only into an idle port, and blocks the port until it
    //   retires. That is what lets the uncached paths ignore the ordering
    //   machinery entirely: while one is in flight there is nothing else
    //   in flight to order it against. It costs the I-port its second
    //   outstanding read for the duration of a bootrom fetch — boot code
    //   runs one fetch at a time, which is the right trade for not
    //   duplicating the queue's blocking logic per target.
    assign icache_rsp_o.ready = tag_init_done && (slot_outstanding[0] < 3'(SKID_DEPTH[0])) &&
        !nc_busy[0] && !((acc_tgt[0] != TGT_CACHE) && (slot_outstanding[0] != 3'd0));
    assign icache_rsp_o.rvalid = (rq_cnt_q[0] != 2'd0) && !rq_blk_q[0][0];
    assign icache_rsp_o.rdata = rq_i_q[0];

    assign dcache_rsp_o.wready = tag_init_done && (slot_outstanding[1] < 3'(SKID_DEPTH[1])) &&
        !nc_busy[1] && !((acc_tgt[1] != TGT_CACHE) && (slot_outstanding[1] != 3'd0));
    assign dcache_rsp_o.rvalid = (rq_cnt_q[1] != 2'd0) && !rq_blk_q[1][0];
    assign dcache_rsp_o.rdata = rq_d_q[0];
    assign dcache_rsp_o.bvalid = 1'b0;  // posted stores, no B channel

`ifdef VERILATOR
    // Wave-trace mirrors of the CPU-facing request fields (the I port is
    // read-only, so there are no we/wdata/wstrb mirrors).
    logic                                       icache_req_valid;
    logic [yarv32_cache_pkg::NATIVE_ADDR_W-1:0] icache_req_addr;
    logic                                       icache_req_rready;
    assign icache_req_valid  = icache_req_i.valid;
    assign icache_req_addr   = icache_req_i.addr;
    assign icache_req_rready = icache_req_i.rready;

    logic                                       itag0_req_valid;
    logic                                       itag0_req_we;
    logic [yarv32_cache_pkg::NATIVE_ADDR_W-1:0] itag0_req_addr;
    logic [                     TAG_DATA_W-1:0] itag0_req_wdata;
    logic [                   TAG_DATA_W/8-1:0] itag0_req_wstrb;
    logic                                       itag0_req_rready;
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
