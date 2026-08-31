# TODO — yarv32 native cache: path to working 2-way set-associative writeback cache on Tang Nano 20K

Target: 2-way set-associative, writeback I/D cache backed by the GW2AR-18's
embedded SDRAM (8 MiB, Gowin HS IP), bitstream for the Tang Nano 20K
(GW2AR-LV18QN88C8/I7, QFN88). Ground rules for every phase: `make sim` green,
`make format-check` clean.

## Decisions (locked 2026-08-31)

- **`HASH_INDEX` dropped.** Classic bit-slice set index only
  (`addr = {tag, set, offset}`, 11-bit tag, 16-bit tag word). The hash
  bought ~nothing at 128 sets / 2 ways and cost a 24-bit non-power-of-2 tag
  word, tag/data index desync, and critical-path XORs.
- **CPU access width is 64 bit.** Response word select is a doubleword
  select, `addr[NBIT_OFFSET-1:3]`.
- **I-mem port: read-only, up to 2 outstanding reads** (the fetch unit
  fills a depth-8 instruction buffer of 32-bit words from the 64-bit
  rdata). The I-cache response path must track two in-flight reads; the
  D-port stays single-outstanding.

---

## Phase 0 — Regressions from the hashing "wip" commit — DONE

All items completed 2026-08-31; `make sim` green, `make format-check` clean.

- [x] D-cache response reads the I-cache line — fixed: `dcache_rsp_o.rdata`
  now selects from `dcache_line`.
- [x] Word select wrong granularity + overrun — fixed: 64-bit doubleword
  select `dw_sel = addr[NBIT_OFFSET-1:3]`, registered as `*_dw_sel_q`, so
  the part-select can never index past the 256-bit line.
- [x] Tag macro address port under-sized — fixed: `TAG_ADDR_W =
  NBIT_SET_IDX + TAG_BYTES_W` on `u_itag`/`u_dtag` + Verilator elaboration
  assert (one tag word per set, 128 words).
- [x] 24-bit non-power-of-2 tag word — gone with the hash (16-bit tag word).
- [x] Hash tag/data index desync — gone with the hash.
- [x] `cache_set_hash` hardcoded geometry — function deleted from the
  package.
- [x] Three conflicting `HASH_INDEX` defaults — parameter deleted
  everywhere (RTL, sim_top, sim/Makefile).
- [x] Hash XOR gates on the request-to-tag-RAM critical path — gone with
  the hash.
- [x] TB gaps: expected-`rdata` checks in phases A and C; preload index is
  the plain set index (no aliasing truncation); Phase-B miss set preloaded
  with a valid tag of a different value (exercises the comparator, not just
  the valid bit); dead `+IINIT/+DINIT` plusarg block, `mask`/`offset`
  arrays, and `icache0_rsp_o_*` tap mirrors deleted.
- [x] Repo hygiene: `sim/hashing/cache_hash_env/` and `sim/hashing/*.png`
  added to `.gitignore` (hash dropped from RTL; `hashing.py` is now a
  historical analysis artifact — delete or keep at your discretion).
- [x] CLAUDE.md geometry docs re-accurate for the classic default; updated
  for the 64-bit word select.

## Phase 1 — Correctness base in the miss FSM — DONE (2026-08-31)

- [x] Line-align SDRAM bursts: `sdrc_addr =
  {miss_addr_q[MEM_SIZE-1:NBIT_OFFSET], {(NBIT_OFFSET-2){1'b0}}}` in both
  `S_WB_REQ` and `S_REFILL_REQ` (the burst no longer keeps the intra-line
  word-select bits, so a mid-line miss cannot straddle two lines).
- [x] Drive `sdrc_dqm = 4'h0` in the FSM defaults block (was never
  assigned: X in sim, undriven net in synthesis).
- [x] SDRAM command encodings moved to `SDRC_CMD_NOP`/`_WRITE`/`_READ`
  localparams in `yarv32_cache_pkg`, used by both the FSM and
  `sim/sdram_stub.sv` — values still placeholders pending the Gowin HS IP
  docs (Phase 5).
- [x] `make clean` fixed: cosim delegations guarded with
  `$(wildcard sim/cosim/*/Makefile)`.

## Phase 2 — Request/tag pipeline — DONE (2026-08-31)

- [x] Registered request skid (`req_q`/`req_q_valid`/`lookup_q`/`miss_seen_q`
  per cache): the address split, tag/data macro lookups, and tag compare all
  run off the registered request, so the 1-cycle-old tag RAM output is
  compared against the address that launched the lookup — no stale-tag race.
  Hit latency is now 3 cycles (accept, lookup, response stage).
- [x] Lookup issue gated once per request (`cache_lookup_go`): the 8 BSRAM
  macros fire once per accepted request, not every cycle while `rready=1`.
- [x] `miss_pending` is a one-shot per request (`miss_seen_q`), cleared when
  the FSM latches the miss — the FSM no longer re-refills the same line
  forever after returning to S_IDLE. If both caches miss in the same cycle
  the dcache is picked first (fixed priority) and the icache entry waits
  with its skid held until the FSM returns.
- [ ] Directed back-to-back address-change test (the stale-tag race this
  phase fixes) — deferred to the Phase-7 BFM suite.

## Phase 3 — Hit/write path (CPU-visible behavior) — DONE (2026-08-31)

- [x] `rvalid` held until `rready`: per-cache response queue replaces the
  one-cycle lookup pulse — hit data is captured at the tag-answer cycle off
  the RAW macro outputs and held (level) until the CPU pops the head. The
  old `imem_rsp_q`/`dmem_rsp_q`/`way_hit_q`/`dw_sel_q` response stage is
  gone.
- [x] Single-outstanding D-port: `wready = outstanding < 1`, where
  outstanding counts occupied skid slots plus unconsumed queue entries —
  one unread response blocks new requests.
- [x] I-port 2 outstanding: 2-slot skid + 2-deep response queue. The
  address split serves one slot at a time, launch order = accept order, so
  responses are delivered in accept order (the fetch unit's depth-8
  instruction buffer relies on it). A queue entry pushed while an older
  miss was unresolved is blocked behind it (`rq_blk_q` latched at push).
- [x] Compare context registered at lookup launch
  (`cmp_tag_q`/`cmp_dw_sel_q`/`cmp_we_q`): with back-to-back I-port lookups
  the live split has already moved to the next slot when a tag answer
  arrives.
- [x] Store hits are posted stores — accepted, no response, slot freed;
  the data-macro write + dirty bit are Phase 4. Store misses take the
  normal miss path.
- [x] Hits are served while the miss FSM is mid-transit (`wready` no
  longer gated by `S_IDLE`).
- [x] A miss keeps its skid slot occupied (`slot_miss_q`): no younger
  response can pass it, and the slot counts as outstanding — the port
  stays wedged (wready low once outstanding is full) until the Phase-4
  unstall. Interim side effect seen in the TB: a held request re-accepted
  after a miss transit re-misses and re-refills once; harmless, goes away
  with the Phase-4 unstall.
- [x] 64-bit CPU access width — done in Phase 0 (doubleword select
  `addr[NBIT_OFFSET-1:3]` on both caches).
- [x] Sim enlarged (user request): Phase D (held response with `rready=0`,
  `wready` low at 2 outstanding, 2 reads returned in order, queue drains),
  Phase E (hit on way 1 alone — per-way comparator + hit-way data mux),
  Phase F (simultaneous I+D hits), Phase H (D-miss with BOTH ways valid —
  miss-detection half of an eviction). Full eviction (victim selection,
  writeback, line commit, unstall) is Phase 4 and NOT testable yet, so the
  miss phases run last (they wedge their port until the unstall exists).

## Phase 4 — Miss FSM completion (writeback = the "wb" in wb cache)

- [ ] Victim selection: round-robin per set is enough for `N_WAY=2`; latch
  victim way, victim tag, `victim_dirty_q` (and reset it — X-propagates
  outside Verilator).
- [ ] Writeback: read the victim way's line into a dedicated `wb_buf`, burst
  it to `{victim_tag, set_idx, offset}` — **not** `line_buf_q`/`miss_addr_q`
  (today's code would overwrite the missing line's own SDRAM location,
  losing the victim).
- [ ] `S_UPDATE_TAG`: way-indexed tag write (`we=1`,
  `addr=set_idx<<TAG_BYTES_W`, `wdata={tag, dirty, valid}`), line commit of
  `line_buf_q` with full strobe, then unstall the requester and return to
  `S_IDLE`. Unstall = clear `slot_miss_q` on the missed slot (frees the
  outstanding unit and unblocks the queue) + replay the slot's request or
  push its response directly, and clear `rq_blk_q` on entries that were
  latched blocked behind this miss. Watch the macro read/write hazard: the
  line-commit/tag writes collide with lookups launched under the Phase-3
  hit-under-miss `wready` (Gowin BSRAM read-first behavior needed, or gate
  lookups during commit).
- [ ] D-cache store path: byte-strobe muxing into the hit way's data macro
  on a write-hit, set dirty; decide write-allocate vs write-around for
  store misses (write-allocate recommended for a writeback cache).
- [ ] Replace `S_WB_WAIT`'s `sdrc_init_done` placeholder with a real
  write-completion signal; qualify `S_REFILL_WAIT` word captures with a real
  per-word data-valid strobe.

## Phase 5 — Real SDRAM IP integration (Gowin HS)

- [ ] Confirm `sdrc_cmd` encodings against the Gowin HS IP documentation
  (via the shared `SDRC_CMD_*` localparams); today they are placeholders the
  stub merely mirrors.
- [ ] Implement bank/row/col mapping for `sdrc_addr` (Bank_Width=2,
  Row=11, Col=8, CL=3, 32-bit data). Today a naive address slice.
- [ ] Verify against the real IP in the Gowin simulator (the `.vo` netlist
  is not Verilator-simulatable; `sdram_stub.sv` is behavioral only).

## Phase 6 — FPGA build for Tang Nano 20K

- [ ] Create the Gowin project/constraints: target `GW2AR-LV18QN88C8/I7`
  (QFN88), `gw2ar18c-000` speed grade, Tang Nano 20K pinout constraint file
  (`.cst`) — clocks, reset, SDRAM HS IP pins per board schematic.
- [ ] Resource sanity: 2 × 8 KiB cache = data macros 2 KiB/way (2 ×
  18 kb BSRAM blocks per way at 256-bit width), tag macros (4 × 16-bit
  words × 128 sets — trivial), plus I/O and SDRAM controller. Check the
  GW2AR-18's 46 BSRAMs cover data + tags with the chosen tag word width
  (see Phase 0's power-of-2 decision).
- [ ] Add a `gw_sh` synthesis script target (`make fpga`) alongside the IDE
  flow; run GowinSynthesis + timing report, fix critical paths (the
  registered-request Phase-2 work exists for exactly this).
- [ ] Timing constraints: SDRAM HS IP clock (needs its own PLL phase vs the
  system clock per the IP docs), `set_false_path`/multicycle where the IP
  requires it.
- [ ] Board bring-up: minimal fetch loop through the bootrom, then LED/UART
  heartbeat driven by cache hits/misses before any CPU integration.

## Phase 7 — Verification hardening

- [ ] Test through the CPU-facing interface instead of hierarchical taps:
  BFM masters issuing random address streams, self-checking against a
  reference model; directed tests for sets ≥ 64 (tag-depth class),
  unaligned offsets, dirty eviction/writeback, back-to-back address change
  (stale-tag race), and — once store path exists — store/load pairs that
  alias across ways and sets.
- [ ] Then the planned `make sw`/`sw-run`/`cosim` flow: RISC-V toolchain,
  `sim/sw` quicksort, Spike golden model, per-retire pc + register diff.

## Phase 8 — Cleanup (interleave with the above)

- [ ] Collapse the duplicated I/D always_comb blocks and macro instances
  behind a generate-for over the two caches (CLAUDE.md item 18).
- [ ] Delete dead code: `offset`/`set_idx`/`tag` arrays' dead consumers,
  remaining VERILATOR tap mirrors, `cache_req_t`/`cache_rsp_t`/
  `CACHE_WIDTH` if unused, `native_ram`'s unused `REQ_ADDR_W`.
- [x] Fix stale sim_top phase comments (Phase A actually uses set 13 /
  tag 0x3CD, not "addr 0 set 0") — done in Phase 0 (comments rewritten with
  the rdata checks).
- [ ] `sim/Makefile`: make `build` a stamped file target; document or remove
  the `-Wno-MULTIDRIVEN` waiver; consider removing `-Wno-UNUSED` (it hid the
  dead `dcache_line`).
- [ ] Update CLAUDE.md to match reality (geometry, protocol status, this
  plan superseding the inline one).