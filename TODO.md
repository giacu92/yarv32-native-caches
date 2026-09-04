# TODO — yarv32 native cache: path to working 2-way set-associative writeback cache on Tang Nano 20K

Target: 2-way set-associative, writeback I/D cache backed by the GW2AR-18's
embedded SDRAM (8 MiB, raw pin interface — see Phase 5), bitstream for the
Tang Nano 20K
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

## Phase 4 — Miss FSM completion (writeback = the "wb" in wb cache) — DONE (2026-08-31)

- [x] Victim selection: prefer an invalid way, else per-set round-robin
  pointer `rr_q[c][set]` (toggled on every miss, enough for `N_WAY=2`).
  Victim way/tag/valid/dirty are captured per-slot at the miss pulse
  (`victim_way_q`/`victim_valid_q`/`victim_dirty_q`/`victim_tag_q`,
  reset like all flops).
- [x] Writeback: the victim line is streamed straight from the data macro's
  registered `rdata_q` output (`fsm_victim_line`) — no `wb_buf` copy needed
  because the lookup gate (`fsm_lookup_gate`) holds the macro still during
  `S_WB_READ`→`S_WB_WAIT`. The burst goes to the VICTIM's address
  `{victim_tag, set, 5'h0}` — not `miss_addr_q` (which would clobber the
  missing line's own SDRAM location, losing the victim).
- [x] `S_UPDATE_TAG` → new `S_UNSTALL` state: one-cycle posted line commit
  (full strobe) + way-indexed tag write (`addr = set << TAG_BYTES_W`,
  `wdata = {tag, dirty, valid}`), both accepted at the same edge. Unstall
  frees the missed skid slot, clears `slot_miss_q` and `rq_blk_q`, and for a
  load pushes the refilled doubleword into the response queue in accept
  order (4-way: pop / unblocked-head / blocked-head / empty queue); a store
  gets no response (posted, write-allocated dirty). Lookups are gated only
  for the FSM-owned cache during `S_WB_READ`/`S_WB_REQ`/`S_WB_WAIT`/
  `S_UPDATE_TAG` — hit-under-miss survives the refill; the D-port store-hit
  path and the FSM writes are mutually exclusive (single-outstanding D).
- [x] D-cache store path: store-hit writes the hit way's data macro with
  the byte-strobe positioned by `cmp_dw_sel_q` and sets the tag's dirty bit
  in the same cycle (posted). Store misses are WRITE-ALLOCATE: the refill
  is merged with the store bytes (`commit_line`) and committed DIRTY.
- [x] Replace `S_WB_WAIT`'s `sdrc_init_done` placeholder with a real
  write-completion signal; qualify `S_REFILL_WAIT` word captures with a real
  per-word data-valid strobe — resolved by the Phase-5 controller swap
  (2026-09-02): writeback words complete on the sdram_controller's busy
  fall, refill words are captured on its rd_ready pulse.
- [x] Sim: Phase M (B's miss completes, unstall serves the refill, the
  re-request hits), Phase S (posted store hit, read-back, neighboring
  doubleword untouched), Phase V (dirty eviction with both ways valid:
  round-robin victim, writeback lands at the victim's address, evicted line
  survives the round-trip, rest of line intact) and Phase V4 (store-miss
  write-allocate: partial-strobe store merged into the refilled line).

## Phase 5 — SDRAM controller integration — DONE (2026-09-02), follow-ups below

The Gowin HS IP was DROPPED (folder `src/ips/sdram_controller_hs` deleted,
recoverable from git history): the core ships only encrypted (`.vg`) or as
a non-Verilator-simulatable primitive netlist (`.vo`), the command
encodings were unconfirmed placeholders the sim stub merely mirrored, and
without IP docs on the build machine the Phase-5 verification items were
unachievable. Replaced by **stffrdhrn/sdram-controller** (BSD), now a git
submodule at `src/ips/sdram-controller`, branch `gw2ar-32bit`:

- [x] Controller adaptation (submodule branch `gw2ar-32bit`):
  `DATA_WIDTH` parameter (32 for the GW2AR-18 embedded SDRAM — upstream
  hardcoded 16), `dqm[3:0]` port replacing the two 1-bit byte masks,
  zero-width-replication fixes in the SDRAM address paths (upstream never
  hits them at Row=13, Row=11 does), `CMD_MRS` x-bit cleaned, refresh
  counter widened / explicit zero compares for Verilator WIDTH-cleanliness.
- [x] Geometry: Row=11, Col=8, Bank=2, CL=3, BL=1, 32-bit data = 8 MiB;
  host address is the 32-bit word index `{bank, row, col}` = `byte[22:2]`
  — the bank/row/col mapping question is answered by construction (the
  controller does the mapping; the FSM passes a plain word address).
- [x] `cache_cntrl` miss-FSM reworked to the controller's host interface:
  one 32-bit word per transaction (no bursts). `S_WB_ISSUE`/`S_REFILL_ISSUE`
  hold `wr/rd_enable` until `busy` rises (refresh may delay the accept),
  writeback words complete on the busy fall, refill words are captured on
  the `rd_ready` pulse — no placeholder completion signals left.
- [x] Sim: `sdram_stub.sv` (transactional HS-IP stub that mirrored the
  FSM's own placeholder encodings) deleted; new `sim/sdram_model.sv` is a
  behavioral pin-level SDRAM (CL=3, BL=1, auto-precharge, row-open
  tracking, MRS value check). The REAL controller RTL now runs in the
  Verilator sim against it, so command encodings, ACT/precharge
  sequencing, and read timing are verified end-to-end, not mirrored.
- [x] `make sim` green (all phases incl. dirty eviction + writeback
  round-trip), `make format-check` clean.

Follow-ups (open):

- [x] **Push the `gw2ar-32bit` branch**: done — `.gitmodules` points at the
  fork `github.com/giacu92/sdram-controller`, and a fresh
  `git submodule update --init` fetches the branch.
- [ ] The fork still has NO LICENSE file (upstream claims BSD only in its
  README) — add one.
- [x] FPGA clocking: 50 MHz single clock domain. `cache_cntrl` takes a
  `CLK_FREQ_MHZ` parameter (default 100 = the sim's clock) that feeds the
  controller's `CLK_FREQUENCY` refresh spacing; `fpga_top` passes 50.
  `sdram_clk_o` is no longer tied to `clk_i`: `cache_cntrl` forwards a new
  `sdram_clk_i` port, which `fpga_top` drives from the rPLL's CLKOUTP with
  a static 180-degree shift (`PSDA_SEL="1000"`). The shift is a bring-up
  starting point, not a measured optimum — see the sweep note in
  `fpga_top.sv` if reads are flaky on the board.
- [ ] Optional perf: BL=1 + auto-precharge costs ~10 cycles per word
  (~80 cycles per line refill, ~160 with a dirty writeback). If that
  starves the CPU, a burst-capable controller is the upgrade path
  (revisit the Gowin HS IP once its docs are at hand, or extend upstream).

## Phase 6 — FPGA build for Tang Nano 20K — IN PROGRESS

Done 2026-09-04 (`make sim`, `make bist`, `make lint-fpga`, `make
format-check` all green):

- [x] FPGA top wrapper `src/rtl/fpga_top.sv` with the toolchain's fixed
  embedded-SDRAM port names (`O_sdram_*` / `IO_sdram_dq`), the 25 -> 50 MHz
  rPLL, the phase-shifted SDRAM clock, reset synchronization and status
  LEDs.
- [x] Bring-up traffic generator `src/rtl/cache_bist.sv`: 8 stores to one
  set (different tags each, so a 2-way cache evicts through the writeback
  path), 8 compares on read-back, then I-port fetches for liveness, with a
  watchdog so a stuck port shows FAIL instead of a dark board. Without a
  driver on the CPU ports the synthesizer would prune the whole subsystem.
- [x] `sim/bist_tb.sv` + `make bist`: runs exactly what the bitstream runs
  (fpga_top with the rPLL bypassed, the real controller, the SDRAM model)
  and fails on either a compare mismatch or a timeout. Negative-control
  checked: inverting the compare makes it fail.
- [x] Gowin project + constraints: `yarv32_cache.gprj`,
  `src/phys/yarv32_cache.cst` (clk PIN10, rst PIN88, LEDs 15-18; the SIP
  SDRAM deliberately gets no entries), `src/phys/yarv32_cache.sdc`
  (25 MHz reference, 50 MHz generated core clock, false paths), and the
  `impl/` Tcl wrappers + process config. `.gitignore` now tracks these and
  ignores only what a run generates.
- [x] `make fpga` / `fpga-synth` / `fpga-pnr` (Tcl wrappers via `gw_sh`,
  headless), plus `make lint-fpga` as a toolchain-free elaboration gate.
  gw_sh is not installed on this machine — pass `GW_SH=<path>` or run on
  the Gowin host.

Open:

- [x] First synthesis run on the Gowin host surfaced two errors, both
  fixed: `EX1998` (net `bootr_req.valid` has no driver — the bootrom port
  is now tied off to `'0` until a fetch mux exists) and `RP0002` (136
  BSRAMs against the device's 46). The BSRAM blow-up was byte write
  enables: Gowin BSRAM has none, so a byte-writable 256-bit line macro is
  built from 32 byte-wide blocks instead of 8 (4 data macros = 128, plus 2
  per tag macro = 136 exactly). `native_ram` gained a `BYTE_WRITE`
  parameter, all eight cache macros set it to 0, and the D-cache store hit
  became a whole-line read-modify-write merging into `dcache_line`, which
  the hit way already has on its output. Expected mapping now: 8 blocks per
  data macro (32) + 1 per tag macro (4) = 36 of 46. New TB phases S3/S4
  cover the partial-strobe store hit and its neighbour.
- [x] SDC error `TA2003` ("Can't set timing constraint to object
  sdram_clk") plus `TA1052` ("Generated clock is ignored"): the explicit
  `create_generated_clock` on the SDRAM clock is gone. That net drives
  nothing but the `O_sdram_clk` pin, so it does not survive as a
  constrainable object, and nothing is lost — Gowin auto-derives a clock on
  the rPLL output and no fabric logic runs on it.
- [x] Local pre-synthesis gate `make lint-yosys` (`scripts/yosys_check.sh`,
  sv2v + yosys): fails on undriven nets (the EX1998 class — verified: it
  fails when the bootrom tie-off is removed) and reports a BSRAM count
  against 46 (currently 36). Caveat, measured: yosys reports 36 either way,
  so it would NOT have caught the byte-enable blow-up — GowinSynthesis's
  memory mapping is its own.
- [ ] Re-run the flow: synthesis + PnR on the Gowin host, confirm the BSRAM
  count, read the timing report, fix critical paths at 50 MHz.
- [ ] Constraints follow-up after the first PnR: whether the SDRAM
  interface needs `set_input_delay`/`set_output_delay` or a multicycle
  path once real numbers exist (today only the false paths are declared).
- [ ] Original wording of the project/constraints item, for reference:
  target `GW2AR-LV18QN88C8/I7`
  (QFN88), `gw2ar18c-000` speed grade, Tang Nano 20K constraint file
  (`.cst`) — clocks, reset, LEDs. NOTE: the embedded SDRAM is SIP — it
  gets NO `.cst` entries; the toolchain connects it automatically when the
  FPGA top-level ports use the fixed names `O_sdram_clk`, `O_sdram_cke`,
  `O_sdram_cs_n`, `O_sdram_cas_n`, `O_sdram_ras_n`, `O_sdram_wen_n`,
  `O_sdram_dqm`, `O_sdram_addr`, `O_sdram_ba`, `IO_sdram_dq` — so the
  cache subsystem needs an FPGA top wrapper exposing exactly those names
  (cache_cntrl's own ports are `sdram_*_o`, close but not identical).
- [ ] Resource sanity: 2 × 8 KiB cache = data macros 2 KiB/way (2 ×
  18 kb BSRAM blocks per way at 256-bit width), tag macros (4 × 16-bit
  words × 128 sets — trivial), plus I/O and SDRAM controller. Check the
  GW2AR-18's 46 BSRAMs cover data + tags with the chosen tag word width
  (see Phase 0's power-of-2 decision).
- [ ] Board bring-up. LEDs (active low, lit = signal true): [0] fail,
  [1] pass, [2] busy, [3] heartbeat, [5:4] fail code (00 none, 01 data
  mismatch, 10 D-port watchdog, 11 I-port watchdog). A dark heartbeat
  points at the clock/reset; busy stuck lit points at a port that never
  answers; fail lit means the test finished badly and the code says how.
  First run on the board (2026-09-04) reported FAIL with the heartbeat
  alive — the fail code was added in response, and the second run read
  back code 10, D-PORT WATCHDOG: the SDRAM round trip never completes, so
  the BIST sits on a store/load until the watchdog fires. That is a stuck
  handshake, not wrong data, so the miss-FSM state at the failure is now
  latched and displayed too (second LED frame). Next run: read that state.
  `S_REFILL_ISSUE`/`S_WB_ISSUE` means the controller never raised busy;
  `S_REFILL_WAIT` means `rd_ready` never pulsed; `S_WB_WAIT` means busy
  never fell. If the code ever turns into 01 (data mismatch) instead, the
  lever is the clock phase: sweep `SDRAM_PSDA_SEL` in `fpga_top`
  ("1100" = 270 deg, "0100" = 90 deg).
  Third run read back state `S_IDLE`: the miss FSM was doing NOTHING when
  the D-port watchdog fired, so the stall is in the cache's own
  request/response handshake (a `wready` or `rvalid` that never comes), not
  in the SDRAM path. Two encoded LED fields are not enough to localize
  that, so bring-up now has a real console: `dbg_uart_tx` + `dbg_reporter`
  print a `"F.. G.. C.. D.. B.. I.. S.."` line on PIN69 (115200 8N1).
  Fourth run read `F2 C0 B6 I0 S1`: fail code 2 (D-port watchdog), miss FSM
  idle, and the LIVE stage already back at `S_DONE` — which is why the
  stage and the D-port occupancy are now latched at the failure too (`G`
  and `D`). `D` is `{slot occupied, lookup launched, miss awaiting FSM
  pickup, queue non-empty}`, so the next line separates the three ways a
  D-port transfer can wedge: never accepted (slot occupied, no progress),
  accepted but the miss never picked up, or answered but the response
  never popped.
  Fifth run read `F2 G1 C0 DC B6 I0 S1`: the failure is on the FIRST store
  (`G1`, `I0`), the miss FSM is idle, and `D=C` says the skid slot is
  occupied with its lookup marked launched but NO miss pending and NO
  queued response — the request went in and nothing ever came back out. A
  final-state snapshot cannot separate "the tag answer never arrived" from
  "it arrived and the slot was never freed", so `cache_cntrl` now counts
  the four steps a request passes through (`dbg_cnt_o`, printed as
  `L P M U`: lookups, tag answers, misses picked up, unstalls). Next run:
  the first of the four that stopped advancing is the step that never
  happened. Simulation prints `L4 P4 M4 U3` at the same point, so any
  count stuck at 0 on the board is the divergence.
  Sixth run read `... L0 P0 M0 U0` next to the latched `D=C` — a
  contradiction, since `slot_lookup_q` (the `D` bit) and the `L` counter
  are driven by the same `cache_lookup_go[1]`. The two simply described
  different instants: `D` is latched at the failure, while the counters
  were read afterwards, and the old watchdog path fell through to `S_DONE`,
  which drops the stalled request and lets the port recover. The BIST now
  HOLDS the hung stage instead (`hung_q`), so the live fields are the stall
  itself, and two more live fields were added: `E` (D-port bits) and `W`
  (`{wready, rvalid, req.valid, we}` as the master sees them). Verified in
  simulation with a forced hang: the post-mortem line reads
  `F2 G1 C0 D4 B1 I0 S1 LF PF M1 U1 E8 W3`.
- [x] ROOT CAUSE of the board hang, from the frozen line
  `F2 G1 C0 DC B1 I0 S1 L0 P0 M0 U0 EC W3`: `W3` says the master holds a
  store with `wready` low, `E=C` says a skid slot is occupied with its
  lookup already marked launched, and `L0` says `cache_lookup_go[1]` never
  fired — which is consistent only if `slot_lookup_q` came up SET, because
  `cache_lookup_go = skid_valid && !slot_lookup`. Those flops were never
  reset on the device: `cache_cntrl` declared its state as UNPACKED arrays,
  which synthesis treats as memories (yosys: 51 "Replacing memory" lines)
  and may implement as LUT-RAM/BSRAM, which has no reset. Every state and
  control array is now a packed vector, which cannot be inferred as
  memory. Simulation could never have caught this: there an unpacked array
  is just flops that reset.
- [ ] The packed-array fix did NOT clear the board hang: build `V4` reports
  the same `F2 G1 C0 DC B1 I0 S1 L0 P0 M0 U0 EC W3`. So the two readings
  that cannot both be true still stand — `E=C` says the skid slot is
  occupied with its lookup marked launched, `L0` says `cache_lookup_go[1]`
  never fired. Build `V5` settles which one lies: `A` counts D-port
  ACCEPTS, and the slot cannot be occupied without one, so `A0` would
  indict the counter path itself rather than the events. `K` and `R` tap
  the lookup issue and the macro answers live ({go, fsm gate, tag valid,
  tag wready} and {tag rvalid, data rvalid, slot_rsp[0], slot_rsp[1]}),
  which with the hang hold are the values AT the stall.
  Build `V5` answered: `A0`. The skid slot is occupied and NO accept was
  ever counted — the two cannot both be true of a running design, so the
  events did not happen and the state was already there: `cache_cntrl`'s
  flops are sitting at power-up values, not at reset values. The RTL reset
  is complete (checked line by line), so the suspect is the reset PULSE.
  `fpga_top` derived it from `rst_i` (a released button) and `pll_lock`
  (possibly already high at configuration): if neither produces a falling
  edge, the design is never reset at all. Build `V6` replaces that with a
  counter-based power-on reset that depends on no edge — it holds the
  fabric in reset for 4096 clocks and releases — and adds `T`, a
  free-running tick inside `cache_cntrl` that MUST change between report
  lines. If `T` is frozen, that module's clock is dead and every counter
  above is meaningless; if `T` moves and `A` is still 0, the accept path
  itself is at fault.
- [x] ROOT CAUSE (2026-09-04, found by gate-level simulation): the tag RAMs
  were never invalidated. Nothing in the design cleared the valid bits, so
  the cache trusted whatever state its tag memory woke up in. RTL
  simulation passed only because Verilator reads an uninitialised array as
  zero. The gate-level run (`make gatesim`: yosys netlist, Icarus, 4-state)
  reproduces the board exactly — the VCD shows reset released at 81.93 us
  and `skid_valid_q[1][0]` going X two cycles later, the X propagating
  through the hit/miss decision into `wready`, and the BIST wedging on its
  first store, which is the `F2 G1 C0 DC ... W3` line the board prints.
  Fix: `cache_cntrl` sweeps every set at reset writing `valid=0` into all
  four tag macros and holds both ports' `wready` low for those N_SETS
  cycles. `sim_top`'s hierarchical tag preload now waits for
  `tag_init_done`, or the sweep would wipe it.
  Scope check (control test, not assumption): disable the sweep and fill
  the RAMs with DEFINED junk (`+RAM_GARBAGE`) and both testbenches still
  pass — garbage tags only cause spurious misses and writebacks. So the
  sweep fixes X propagation and any device whose RAM wakes up non-zero, but
  it does not explain the board hang. That one is still open: on the board
  `cache_cntrl`'s flops do not advance at all (`T` frozen, `A0`), which no
  simulation here reproduces — the gate-level netlist clocks `tick_q`
  40904 times. Next datum: `led_o[5]` (pin 20) carries `tick_q[24]` through
  nothing but a wire, so it blinks if and only if that module is clocked.
- [x] `led_o[5]` BLINKS at ~1.5 Hz on the board: `cache_cntrl` IS clocked,
  and the "frozen module" reading was wrong. The `T` field was constant
  because the probe was ALIASED — it exported `tick_q[15:12]`, period 2**16
  clocks, while the reporter samples every 2**24 clocks, an exact multiple,
  so every sample landed on the same phase. A constant probe reads exactly
  like a dead clock; the field now uses bits that are not commensurate with
  the sample period.
- [x] ROOT CAUSE (board), consistent with every reading once the clock is
  known good: the fabric is NEVER RESET. `cache_cntrl`'s flops sit at
  power-up values — `skid_valid_q[1][0]=1` fills the only outstanding slot
  so `wready` can never rise (hence `A0`, no accept ever), and
  `slot_lookup_q[1][0]=1` keeps `cache_lookup_go` low forever (hence `L0`).
  The V6 power-on counter could not help: `por_cnt_q` has no reset of its
  own, so if it powers up at all-ones `por_done` is true from the first
  instant, `rstn_raw` is high from the start, the synchroniser never sees an
  edge, and no reset pulse is ever produced. The Gowin process config had
  `"Initialize_Primitives": false`, which is what leaves those power-up
  values undefined. Fix (build `V10`): explicit initial values on the reset
  chain (`por_cnt_q`, `rstn_sync_q`) plus `Initialize_Primitives` /
  `-init_primitives 1` so the device honours them.
- [x] Second real divergence, found while auditing the same class: the
  SDRAM power-up wait. The controller leaves reset after 15 NOP cycles
  (300 ns at 50 MHz); the device requires at least 100 us of stable clock
  and NOPs before it accepts PRECHARGE / REFRESH / MRS, so on hardware the
  mode register was never programmed. `cache_cntrl` now holds the
  controller in reset for `SDRAM_INIT_US` (200 us, sized from
  `CLK_FREQ_MHZ`), and `sdram_model` enforces the window plus MRS-before-
  access and tRP / tRFC / tRCD, with both testbenches failing on any
  violation. Verified both ways: with the hold the sim passes; with
  `SDRAM_INIT_US = 1` the model reports the early commands and the run
  fails.

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