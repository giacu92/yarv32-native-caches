# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

RISC-V 32-bit (yarv32) cache subsystem targeting a Gowin GW2AR-18 FPGA
(GW2AR-LV18QN88C8/I7). Harvard split I-cache / D-cache backed by 8 MiB
internal SDRAM (23-bit address space), plus a small read-only bootrom.

## Commands

Formatting and simulation are driven by the top-level `Makefile` (the FPGA
bitstream build runs through the Gowin IDE / `gw_sh`, not this Makefile).

- `make format` — reformat every SystemVerilog file in place with
  `verible-verilog-format` (policy in `verible.flags`: 4-space indent,
  100-col limit, aligned ports/params/connections/assignments).
- `make format-check` — exit 1 if any file is unformatted (CI / pre-commit).
- `make format-diff` — print a unified diff of pending formatting changes.
- `make sim` / `make run` — build + run the Verilator sim (delegates to
  `sim/Makefile`; requires `verilator`).
- `make wave` — build + run the sim, then open `sim/sim_top.vcd` in
  `gtkwave`.
- `make sw` — build the quicksort C program with the
  `riscv32-esp-elf-gcc` toolchain into `sim/sw/quicksort/build/{imem,dmem}.hex`
  (Harvard link: `.text`→IMEM, `.data`→DMEM).
- `make sw-run` — build the C program and run the sim loading it via
  `+IINIT=.../+DINIT=...` plusargs instead of the hand-crafted hex oracle.
- `make cosim` — build Spike (golden ISA reference) + the C program, run
  both, and diff per-retire pc + register writes (first run needs Spike
  build deps, see `sim/cosim/build_spike.sh`).
- `make clean` — remove simulation build artefacts + waveforms.

`make sim` and `make wave` work: they delegate to `sim/Makefile`, which
builds the cache with Verilator (`--binary --timing --trace`) and runs
`sim/sim_top.sv`. `make sw`/`sw-run`/`cosim` still require the RISC-V
toolchain + `sim/sw` + `sim/cosim` trees, not yet present. Requires
`verible-verilog-format` on PATH; `make sim`/`wave` additionally require
`verilator` (>= 5.x, for `--timing`) and `gtkwave`.

## Files

- `src/rtl/cache_cntrl.sv` — top-level cache controller: address split,
  tag RAM wiring, per-way tag compare, miss-handling FSM, SDRAM controller
  instance.
- `src/rtl/native_ram.sv` — generic single-clock BSRAM wrapper implementing
  the native `mem_req_t`/`mem_rsp_t` protocol (see below). Parametrized by
  `ADDR_W`, `DATA_WIDTH`, `READ_ONLY`. Used for bootrom, cache data
  macros, and tag macros.
- `src/rtl/pkg/yarv32_cache_pkg.sv` — width-parametrizable protocol
  struct pair. SystemVerilog packages cannot parameterize typedefs, so the
  `` `YARV_MEM_TYPES``/`` `YARV_MEM_REQ_T``/`` `YARV_MEM_RSP_T`` macros build
  the req/rsp pair per (ADDR_W, DATA_W) with fixed field order/semantics.
  The package instantiates the fixed-width variants: `mem_req_t` /
  `mem_rsp_t` (64-bit data, `MEM_WIDTH`/`STRB_WIDTH`) and `cache_req_t` /
  `cache_rsp_t` (256-bit data, `CACHE_WIDTH`). `native_ram` takes the pair
  as `parameter type REQ_T/RSP_T` (defaults: the CPU-width pair), and
  `cache_cntrl` defines local `way_req_t`/`way_rsp_t` (line width) and
  `tag_req_t`/`tag_rsp_t` (tag width) from the same macros and passes them
  to its macro instances — so port widths match at every width, verified by
  elaboration-time `$bits` checks, and a WIDTH lint warning now means a
  real bug (the sim Makefile no longer waives `WIDTH`/`WIDTHEXPAND`).
- `native_ram` parameters: `ADDR_W`, `DATA_WIDTH`, `REQ_ADDR_W` (addr
  field width, default `MEM_WIDTH`; the RAM decodes only the low `ADDR_W`
  bits), `READ_ONLY`, `INIT_FILE` (optional `$readmemh` preload, sim only),
  and `REQ_T`/`RSP_T` (protocol struct pair, see above).
- `src/ips/sdram_controller_hs/` — Gowin SDRAM HS IP core (generated,
  read-only): `.ipc`, `_tmp.v`, `.vo`. `CL=3`, `Data_Width=32`,
  `Addr_Column_Width=8`, `Addr_Row_Width=11`, `Bank_Width=2`. The `temp/`
  subfolder holds IP build logs/reports — do not hand-edit.
- `sim/sim_top.sv` — Verilator testbench / sim top (clock, reset, drives
  the I/D-cache `mem_req_t` interfaces, dumps `sim_top.vcd`). Compiles with
  `--timing`. Self-checking: three phases (I-hit / I-miss / D-hit) with
  PASS/FAIL counters and a 300-cycle watchdog; assertions are on
  hierarchical internals (`u_dut.icache_hit`, `u_dut.state_q`), not the
  CPU-facing outputs, because those are undriven (see TODOs). Preloads the
  tag/data macros by hierarchical reference (`u_dut.gen_way[w].u_itag.mem`
  etc.) at time 0. `+IINIT`/`+DINIT` plusargs are echoed but ignored —
  the preload is always the hierarchical one above.
- `sim/sdram_stub.sv` — behavioral replacement for `SDRAM_Controller_HS_Top`
  (identical port list). The real IP netlist (`.vo` Gowin primitives /
  encrypted `.vg`) is not Verilator-simulatable, so the sim file list
  includes this stub instead of `src/ips/...`. Transactional model: 8 MiB
  backing array, combinational `cmd_ack`, streams refill data one
  32-bit word/cycle (matches the FSM's `S_REFILL_WAIT`). Its `CMD_WRITE`/
  `CMD_READ` encodings mirror the FSM's *placeholder* values, so the sim
  cannot catch a wrong command encoding against the real IP.

## Protocol: mem_req_t / mem_rsp_t

Custom native protocol, not AXI. See `native_ram.sv` header comment for
full timing. Key points:

- Launch: `req.valid && rsp.wready` (`wready` = idle / can accept).
- Read response: `rsp.rvalid && req.rready`, held until consumed
  (compliance fix — not a one-cycle pulse).
- Single-outstanding: one unread read response blocks new requests.
- Store commits combinationally at the accept cycle; no B channel
  (`bvalid` always low), posted-store semantics.

## Naming convention

- Module ports: `*_i` (input) / `*_o` (output).
- Internal wires/regs: no prefix.
- Flops (registered signals): `_q` suffix, next-state value `_d`.

## Cache configuration (cache_cntrl parameters)

| Parameter    | Default | Meaning                              |
|--------------|---------|--------------------------------------|
| `MEM_SIZE`   | 23      | SDRAM address width (8 MiB)           |
| `CL_SIZE`    | 5       | Cache line size, 2^5 = 32 B          |
| `N_WAY`      | 2       | Set associativity                    |
| `CACHE_SIZE` | 13      | Total size per cache (I or D), 8 KiB |

Derived geometry: `N_LINES=256`, `N_SETS=128`, `NBIT_OFFSET=5`,
`NBIT_SET_IDX=7`, `NBIT_TAG=11` (+ valid/dirty bits). The cache data RAM
is one word wide per line: `DATA_WIDTH = 2^(CL_SIZE+3) = 256` bits, so a
whole line is stored in a single 256-bit BSRAM word. SDRAM refill/writeback
moves `BURST_LEN = DATA_WIDTH/32 = 8` words over the 32-bit SDRAM data bus.

Tag word layout: `rdata[0]=valid`, `rdata[1]=dirty`, `rdata[2+:TAG_FIELD_W]=tag`.

Two non-obvious details in this wiring:

- Tag macro addressing: `native_ram` drops the low `BYTES_W` bits of
  `addr` as a byte-select within the tag word (tag words are
  `TAG_DATA_W` ≥ 8 bits). `set_idx` must therefore be left-shifted by
  `TAG_BYTES_W` before being placed in `itag_req/dtag_req.addr`, or
  consecutive sets alias to the same tag word.
- Struct-to-struct port connections are packed-vector assignments (no
  strict type checking), so every width that appears on a native-protocol
  port must come from the same macro expansion as its counterpart —
  `way_req_t`/`way_rsp_t` for the data macros, `tag_req_t`/`tag_rsp_t`
  for the tag macros, `mem_req_t`/`mem_rsp_t` for the CPU side and
  bootrom. Verilator `WIDTH` warnings are no longer waived in
  `sim/Makefile`, so a mismatched pair fails the build.

Set-associativity is implemented via a `generate for (w = 0; w < N_WAY; w++)`
loop instantiating `N_WAY` parallel `native_ram` macros for data and for
tags, both for I-cache and D-cache. Data macros are sized
`WAY_ADDR_W = CACHE_SIZE - $clog2(N_WAY)` (halved per doubling of ways, so
total capacity is unchanged). Tag macros stay `NBIT_SET_IDX` wide — already
per-set, unaffected by way count. The tag lookup request (`set_idx`) is
broadcast to all ways in parallel; tag compare and hit detection are fully
parallel (`N_WAY` comparators per cache), not time-multiplexed.

The bootrom is a 2 KiB (`ADDR_W=11`) read-only `native_ram` instance; its
`bootr_req`/`bootr_rsp` are currently undriven (no CPU-side fetch mux yet).

## Current state / known TODOs

The miss-handling FSM (`cache_cntrl.sv`, `S_IDLE` → `S_ARBITRATE` →
`S_WB_REQ`/`S_WB_WAIT` → `S_REFILL_REQ`/`S_REFILL_WAIT` → `S_UPDATE_TAG`)
is a skeleton. Hit *detection* is combinational (parallel tag compare) and
never enters this FSM; only a miss triggers arbitration for the shared SDRAM
controller (dcache wins ties, fixed priority). Open items, marked `TODO` in
source:

- SDRAM HS IP `sdrc_cmd` encoding not yet confirmed against IP
  documentation (currently placeholder values).
- `sdrc_addr` bank/row/col mapping not implemented (currently a naive
  address slice).
- Victim way selection (LRU / round-robin per set) not implemented —
  `victim_dirty_q` is unconnected.
- `S_UPDATE_TAG` does not yet drive `itag_req`/`dtag_req` (way-indexed
  tag write) or `imem_req`/`dmem_req` (line commit), and does not unstall
  `icache_rsp_o`/`dcache_rsp_o`.
- Cache data path (`imem_req[w]`/`dmem_req[w]`) is wired to the RAM
  macros; hit-store `wstrb` muxing is still TODO (`wstrb` tied to 0 in the
  speculative-read block). The `imem_rsp_q`/`dmem_rsp_q` pipeline registers
  feed the hit-way line mux.
- `icache_rsp_o`/`dcache_rsp_o` are driven on a hit (hit-way mux + 32-bit
  word select by intra-line offset, registered one stage after the RAM
  outputs; `wready` only while the miss FSM is idle). A miss still never
  unstalls the requester, and `rdata` is zero-extended 32-bit granularity
  while the CPU-side bus is 64-bit.
- `S_WB_WAIT` keys its completion off `sdrc_init_done` (a placeholder, not
  a real write-completion signal); `S_REFILL_WAIT` assumes one 32-bit word
  per cycle with no per-word data-valid strobe.

## Completion plan

Each phase keeps `make sim` green and `make format-check` clean.

### Phase 1 — Fix review findings (correctness base)

1. Tag macro geometry: `ADDR_W = NBIT_SET_IDX + TAG_BYTES_W` on
   `u_itag`/`u_dtag`; add an elaboration assert that tag macro depth covers
   `N_SETS`. Today `ADDR_W=NBIT_SET_IDX=7` but `native_ram` drops `BYTES_W=1`
   address bits, storing only 64 tag words for 128 sets — set 64 aliases
   onto set 0 (false hits, clobbered tag entries).
2. Line-align SDRAM bursts: `sdrc_addr =
   {miss_addr_q[MEM_SIZE-1:NBIT_OFFSET], {(NBIT_OFFSET-2){1'b0}}}` in both
   `S_WB_REQ` and `S_REFILL_REQ`. Today the burst keeps the intra-line
   word-select bits `addr[4:2]`, so a miss to a mid-line word straddles two
   32-byte lines and commits a half-garbage line.
3. Drive `sdrc_dqm = 4'h0` in the FSM defaults block (never assigned today:
   X in sim, undriven net in synthesis).
4. De-duplicate the SDRAM command encodings: add `SDRC_CMD_*` localparams to
   `yarv32_cache_pkg`, use them in the FSM and in `sim/sdram_stub.sv` so a
   future divergence is a compile error, not a green sim over broken
   hardware.
5. Fix `make clean` (Error 2 today): guard the `sim/cosim/quicksort` and
   `sim/cosim/ecall` delegations with `$(wildcard ...)` until those trees
   exist.

### Phase 2 — Request/tag pipeline

6. Register the request address alongside the tag lookup (a 1-deep skid of
   `{addr, we, wstrb, wdata}` per cache) and compare the tag RAM output
   against the *registered* address. Today the 1-cycle-old tag read is
   compared against the current combinational tag: an address change after
   accept causes false hits (stale data) or spurious misses.
7. Gate lookup issue on "new request not yet looked up" so lookups fire once
   per request instead of every cycle (`rready=1` keeps relaunching all 8
   BSRAM macros; `miss_pending` never drops, which also re-refills the same
   line forever once the FSM returns to `S_IDLE`). Clear `miss_pending` once
   latched.

### Phase 3 — Hit/write path (CPU-visible behavior)

8. Complete `icache_rsp_o`/`dcache_rsp_o`: `rvalid` held until `rready`,
   `wready` deasserted while the miss FSM is mid-transit, and decide the
   64-bit CPU access width (current word select is 32-bit granularity).
9. D-cache store path: byte-strobe muxing into the selected way's data macro
   on a write-hit, set the dirty bit; decide write-allocate vs write-around
   for store misses.

### Phase 4 — Miss FSM completion

10. Victim selection (round-robin per set is enough for N_WAY=2): latch
    victim way, victim tag, `victim_dirty_q` (and reset it — today it
    X-propagates outside Verilator's 2-state zeroing).
11. Writeback: read the victim way's line from the data macro into a
    separate `wb_buf`, burst it to the victim's address
    `{victim_tag, set_idx, offset}` — not `line_buf_q`/`miss_addr_q` (today's
    code would write refill-buffer data over the missing line's own SDRAM
    location, losing the victim).
12. `S_UPDATE_TAG`: tag write (`we=1`, `addr=set_idx<<TAG_BYTES_W`,
    `wdata={tag, dirty, valid}`) to the selected way only, line commit of
    `line_buf_q` with full strobe, then unstall the requester and return to
    `S_IDLE`.
13. Replace `S_WB_WAIT`'s `sdrc_init_done` placeholder with a real completion
    signal, and qualify `S_REFILL_WAIT` word captures with a real per-word
    data-valid strobe.

### Phase 5 — Real SDRAM IP integration

14. Confirm command encodings against the Gowin HS IP docs (via the shared
    localparams from item 4); implement bank/row/col mapping for `sdrc_addr`
    (Bank_Width=2, Row=11, Col=8).

### Phase 6 — Verification hardening

15. Test through the CPU-facing interface instead of hierarchical taps: BFM
    masters issuing random address streams, self-checking against a
    reference model; directed tests for sets >=64 (catches the tag-depth
    class), unaligned offsets, dirty eviction/writeback, back-to-back
    address change (catches the stale-tag race).
16. Then the planned `make sw`/`sw-run`/`cosim` flow (toolchain, `sim/sw`,
    `sim/cosim` trees).

### Phase 7 — Cleanup (can interleave)

17. Delete dead code: the `offset`/`set_idx`/`tag` arrays' remaining dead
    consumers, unused VERILATOR tap mirrors, `cache_req_t`/`cache_rsp_t`/
    `CACHE_WIDTH` in the package, `native_ram`'s unused `REQ_ADDR_W`
    parameter.
18. Collapse the duplicated I/D always_comb blocks and macro instantiations
    behind a generate-for over the two caches.
19. Make `sim/Makefile`'s `build` a stamped file target; document or remove
    the `-Wno-MULTIDRIVEN` waiver; fix stale sim_top phase comments (Phase A
    actually uses set 13 / tag 0x3CD, not "addr 0 set 0").

### Key context

The sim currently passes only because Verilator is 2-state (zeroes the
unreset `victim_dirty_q`), the stub ignores `sdrc_dqm` and mirrors the
placeholder command encodings, and the testbench waits 5 cycles per phase
and only exercises set 0/13 — none of the findings above are caught by the
existing self-checks.

## Tooling

- Synthesis: Gowin EDA (`GowinSynthesis`), target `gw2ar18c-000`.
- Simulation: Verilator-compatible (`ifdef VERILATOR` assertions present
  in `native_ram.sv`); `$readmemh` used for INIT_FILE preload in sim.
- `.vo` files are post-place-and-route simulation netlists — read-only,
  do not hand-edit.