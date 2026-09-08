# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

RISC-V 32-bit (yarv32) cache subsystem targeting a Gowin GW2AR-18 FPGA
(GW2AR-LV18QN88C8/I7). Harvard split I-cache / D-cache backed by 8 MiB
internal SDRAM (23-bit address space), plus a small read-only bootrom.

## Commands

Formatting and simulation are driven by the top-level `Makefile`, which
also wraps the Gowin flow (`make fpga`) — that one needs `gw_sh`, which is
not installed on this machine.

- `make format` — reformat every SystemVerilog file in place with
  `verible-verilog-format` (policy in `verible.flags`: 4-space indent,
  100-col limit, aligned ports/params/connections/assignments).
- `make format-check` — exit 1 if any file is unformatted (CI / pre-commit).
  Run `make format` BEFORE committing: this gate was red for three commits
  because hand-aligned `localparam` groups were committed without it, and
  verible reformats those groups flush under every alignment mode the
  flagfile offers. Do not hand-align declarations.
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
- `make bist` — build + run the FPGA board-top self test sim
  (`sim/bist_tb.sv`: `fpga_top` + `cache_bist` against the SDRAM model —
  the same traffic the Tang Nano 20K bitstream runs). Exits non-zero on a
  compare mismatch or a timeout.
- `make lint-fpga` — elaborate + lint `fpga_top` with Verilator (the rPLL
  hard macro is bypassed under `VERILATOR`). Gate for the board build on a
  machine without the Gowin toolchain.
- `+RAM_GARBAGE` (plusarg) — fill every `native_ram` array with junk before
  time 0 instead of letting simulation hand out zeros for memory nobody
  wrote. The block is excluded from the sv2v/yosys paths by
  `NO_SIM_PLUSARGS` (`scripts/yosys_check.sh`, `scripts/gatesim.sh` pass
  it): yosys reads neither `$test$plusargs` nor sv2v's rendering of a size
  cast, and both scripts preprocess with `-DVERILATOR`. Run it as `make -C sim run RUN_ARGS=+RAM_GARBAGE` (or on the BIST
  binary). A test that passes with it does not depend on that accident.
- `make -C sim xrun` / `xbist` — the same two simulations with Verilator's
  `--x-initial unique`, which randomises uninitialised FLOPS. Note it does
  NOT cover memory arrays (verified: it misses the tag-invalidation bug),
  which is what `+RAM_GARBAGE` is for.
- `make gatesim` — GATE-LEVEL simulation (`scripts/gatesim.sh`): synthesize
  with yosys for Gowin, then run the synthesized netlist against the same
  BIST testbench under Icarus (4-state, so an undriven or contended net
  shows as X instead of silently reading zero). This is what caught the
  missing tag invalidation: RTL simulation cannot see it by construction,
  because it never sees what synthesis built. Needs `sv2v`, `yosys` and
  `iverilog`; `SYNTH_OPTS=-nobram` (etc.) bisects a mapping, and the
  netlist is cached unless the sources change (`FORCE_SYNTH=1` to redo).
- `make lint-yosys` — pre-synthesis check with `sv2v` + `yosys`
  (`scripts/yosys_check.sh`): fails on undriven nets (the Gowin `EX1998`
  class) and reports a BSRAM count against the GW2AR-18's 46 blocks
  (`RP0002`). Its block count is an estimate of what the DESIGN needs, not
  a prediction of GowinSynthesis's mapping — yosys reports the same block
  count with or without `BYTE_WRITE`, while GowinSynthesis needed 136 for
  the byte-writable version. Over the limit means a real problem; under it
  is necessary, not sufficient. It does track `RAM_STYLE`, though: moving
  the four tag macros to LUT SSRAM took the count from 36 to 32, matching
  the block accounting below. Known noise (translation artifacts, not
  defects): sv2v renders `parameter type` ports at their default width
  before yosys specializes them (out-of-bounds range-select warnings on
  `mem_req_i`), and turns an `always_comb` loop variable into a block reg
  (a latch warning on `sv2v_autoblock_*.b`).
- `make fpga` (`fpga-synth` + `fpga-pnr`) — Gowin synthesis and place &
  route through the `impl/*.tcl` wrappers, headless. `gw_sh` is not
  installed on this machine: pass `GW_SH=<path to gw_sh>` or run the
  targets on the Gowin host.

`make sim` and `make wave` work: they delegate to `sim/Makefile`, which
builds the cache with Verilator (`--binary --timing --trace`) and runs
`sim/sim_top.sv`. `make sw`/`sw-run`/`cosim` still require the RISC-V
toolchain + `sim/sw` + `sim/cosim` trees, not yet present. Requires
`verible-verilog-format` on PATH; `make sim`/`wave` additionally require
`verilator` (>= 5.x, for `--timing`) and `gtkwave`.

## Files

- `src/rtl/cache_cntrl.sv` — top-level cache controller: address split,
  tag RAM wiring, per-way tag compare, miss-handling FSM, SDRAM controller
  instance, plus the system address decode (bootrom, control register,
  cache bypass — see "System address map"). CPU-facing ports are the
  yarv32-uc types bit-identically: `ifetch_req_t`/`ifetch_rsp_t` on the I
  side (read-only, 64-bit, 2 outstanding), `mem_req_t`/`mem_rsp_t` on the
  D side (32-bit, single-outstanding, posted stores).
- `src/rtl/native_ram.sv` — generic single-clock BSRAM wrapper implementing
  the native `mem_req_t`/`mem_rsp_t` protocol (see below). Parametrized by
  `ADDR_W`, `DATA_WIDTH`, `READ_ONLY`. Used for bootrom, cache data
  macros, and tag macros.
- `src/rtl/sdram_line_port.sv` — SDRAM word-streaming engine, sitting
  between the miss FSM and the `sdram_controller` submodule. It turns the
  controller's one-word-per-transaction host interface into a "move N
  consecutive words" command, so every per-word handshake rule — hold the
  enable until `busy` rises because a due refresh may delay the accept,
  end a write on the `busy` fall, capture a read on the `rd_ready` pulse —
  lives in one place. A command is accepted on `cmd_valid_i &&
  cmd_ready_o`; `done_o` pulses for one cycle as the last word completes,
  while `cmd_ready_o` is still low, so a caller may drive `cmd_valid_i =
  cmd_ready_o` and cannot re-issue the command it just saw finish. Write
  data is NOT registered (that would be a whole line of flops for
  nothing): the caller holds `cmd_wdata_i` until `done_o` — the cache's
  writeback source is the data macro's registered output, held for exactly
  that window by the lookup gate. Read words accumulate into `rdata_o` and
  HOLD there, so a short read leaves the upper words at whatever the
  previous command left; a caller reads back only the words it asked for.
  Costs one cycle per COMMAND (four per miss at worst), not per word.
- `src/rtl/pkg/yarv32_cache_pkg.sv` — the protocol types.
  SystemVerilog packages cannot parameterize typedefs, so the
  `` `YARV_MEM_TYPES``/`` `YARV_MEM_REQ_T``/`` `YARV_MEM_RSP_T`` macros build
  the req/rsp pair per (ADDR_W, DATA_W) with fixed field order/semantics;
  the package instantiates only `boot_req_t`/`boot_rsp_t` (64-bit data,
  the bootrom macro and `native_ram`'s parameter defaults) from them; the
  line- and tag-width pairs are expanded inside `cache_cntrl` from its own
  geometry parameters instead, so no fixed-width copy of them can drift.
  The two CPU-facing pairs are NOT macro-built — the ports have different
  field sets, so they are hand-declared bit-identical to the yarv32-uc
  core's `rv32_pkg` typedefs: `ifetch_req_t`/`ifetch_rsp_t` ($bits 34/66)
  and the 32-bit `mem_req_t`/`mem_rsp_t` ($bits 71/35; note `mem_req_t`
  is now the LSU pair, not the old 64-bit one). Field ORDER is load-bearing
  (struct connections are packed-vector copies) and pinned by
  elaboration-time `$bits` asserts in `cache_cntrl`. Width constants:
  `NATIVE_ADDR_W` (32, every port's addr field), `IFETCH_DATA_W` (64),
  `LSU_DATA_W` (32), `LSU_STRB_W` (4). The unused `CACHE_WIDTH`,
  `CACHE_STRB_WIDTH`, `MEM_WIDTH` and `STRB_WIDTH` constants and the
  `cache_req_t`/`cache_rsp_t` pair are gone: outside `native_ram` nothing
  checks a native port's addr width against its peer's, so a leftover
  constant at the wrong width was a way to build a pair that connects
  silently. `native_ram` takes its pair as `parameter type REQ_T/RSP_T`
  (defaults: the boot pair), and `cache_cntrl` defines local
  `way_req_t`/`way_rsp_t` (line width) and `tag_req_t`/`tag_rsp_t` (tag
  width) from the same macros and passes them to its macro instances — so
  port widths match at every width, verified by elaboration-time `$bits`
  checks, and a WIDTH lint warning now means a real bug (the sim Makefile
  no longer waives `WIDTH`/`WIDTHEXPAND`/`WIDTHTRUNC`).
- `cache_cntrl` parameters beyond the geometry table below: `BOOTROM_FILE`
  (the bootrom's `$readmemh` image) and `CSR_RST_VAL` (the control
  register's power-on value). `fpga_top` forwards `BOOTROM_FILE`.
- `native_ram` parameters: `ADDR_W`, `DATA_WIDTH`, `REQ_ADDR_W` (addr
  field width, default `NATIVE_ADDR_W`; the RAM decodes only the low
  `ADDR_W` bits), `READ_ONLY`, `BYTE_WRITE`, `RAM_STYLE`, `INIT_FILE`
  (optional `$readmemh` preload, sim only), and `REQ_T`/`RSP_T` (protocol
  struct pair, see above).
- `BYTE_WRITE` is a RESOURCE parameter. Gowin BSRAM has no byte write
  enable, so GowinSynthesis builds one by splitting the array into
  byte-wide blocks: a 256-bit line macro becomes 32 BSRAMs instead of 8,
  i.e. 128 blocks for the four data macros against the GW2AR-18's 46
  (synthesis error `RP0002`). All eight cache macros are therefore
  `BYTE_WRITE(0)` — whole-word writes only, with a Verilator assert that
  fires on a partial strobe. The only partial write in the design, the
  D-cache store hit, merges into the line the hit way already has on its
  registered output (`dcache_line`) and writes it back whole, costing no
  extra cycle and no extra port.
- `RAM_STYLE` is the other RESOURCE parameter: `"block"` (default) puts
  the array in BSRAM, `"distributed"` in LUT-based SSRAM. A Gowin BSRAM
  block holds 18 kb and tops out at a data width of 32, so an array pays
  one block per 32 bits of WIDTH before its depth counts for anything, and
  a small array pays a whole block however little it holds. That is the
  design's whole block budget, measured (yosys, `make lint-yosys`): the
  four 128 x 256 bit data macros are 32 blocks — 8 apiece for width alone,
  using 128 of 512 available words in each — and the four 128 x 16 bit tag
  macros were the other 4, a full block each for 2048 bits, 11% of one.
  The tag macros are therefore `RAM_STYLE("distributed")` and the data
  macros stay in BSRAM (too wide for LUTs); the count went 36 to 32.
  Neither style resets its contents, so the tag invalidation sweep is
  needed either way.
  Two mechanics worth knowing before touching this. A Verilog attribute
  value must be a literal, so the two styles are two separate array
  declarations inside a conditional generate, with everything that names
  the array coming from the `NATIVE_RAM_*` macros defined just above them
  — that is what keeps the branches from drifting apart. And both arms of
  that generate are named `gen_store`, so the storage's hierarchical path
  (`u_<inst>.gen_store.mem`) is the same whichever style an instance
  picked, which is what the testbenches' preloads depend on.
- `src/ips/sdram-controller/` — git submodule of
  `github.com/stffrdhrn/sdram-controller` (BSD), checked out on the local
  branch `gw2ar-32bit` (adapts upstream's hardcoded 16-bit data to the
  GW2AR-18 embedded SDRAM: `DATA_WIDTH` parameter, `dqm[3:0]` port,
  zero-width-replication fixes, Verilator WIDTH-clean compares). Instantiated
  inside `cache_cntrl`; geometry Row=11, Col=8, Bank=2, CL=3, BL=1, 32-bit
  data = 8 MiB. Host interface: one 32-bit word per transaction,
  `{bank,row,col}` word address = `byte[22:2]`, enable-held-until-busy
  accept, `rd_ready` pulse per read word, busy fall ends a write. The
  branch lives on the fork `github.com/giacu92/sdram-controller`, which is
  what `.gitmodules` points at, so `git submodule update --init` in a fresh
  clone fetches it. The fork still has no LICENSE file (upstream claims BSD
  in its README only).
- `src/rtl/fpga_top.sv` — Tang Nano 20K board top: 25 MHz reference into an
  rPLL (clk_core = 50 MHz on CLKOUT, SDRAM clock on CLKOUTP with a static
  180-degree shift, `PSDA_SEL="1000"`), reset synchronization (async
  assert, sync deassert, gated by PLL lock), `cache_bist` + `cache_cntrl`,
  and status LEDs (active low). `led_o[0]` selects the view: dark while
  the test runs or passes ([1] pass, [2] busy, [3] heartbeat), lit once it
  has failed. In the failure view `led_o[1]` is a frame marker blinking at
  the heartbeat rate and `led_o[5:2]` carries the fail code while it is
  dark (`00xx`: 01 data mismatch, 10 D-port watchdog, 11 I-port watchdog)
  and the cache's miss-FSM state while it is lit — two frames because a
  dedicated failure light leaves five LEDs for six bits. The SDRAM clock
  phase is the named `SDRAM_PSDA_SEL` localparam, the one edit a bring-up
  phase sweep needs. The embedded SDRAM is a SIP die with NO `.cst` entries — the
  toolchain connects it by MATCHING TOP-LEVEL PORT NAMES, so the ports are
  `O_sdram_*` / `IO_sdram_dq` (the documented exception to the `*_i`/`*_o`
  convention); renaming one silently disconnects the SDRAM.
- `src/rtl/cache_bist.sv` — bring-up traffic generator driving the two
  CPU-facing ports with the yarv32-uc types (`ifetch_*` fetches, 32-bit
  `mem_*` stores/loads): 8 posted word stores to ONE set with a different
  tag each (a 2-way cache therefore evicts through the writeback path),
  then the same 8 addresses stored TWICE more with partial byte strobes,
  then the same 8 addresses read back TWICE each and compared against the
  byte-wise merge of the three patterns, then I-port fetches checked for
  liveness only (power-on SDRAM content is unknown). Each of those pairs
  covers two different paths: the first partial store takes a store miss
  and merges into the REFILLED line, the second hits and merges into the
  RESIDENT one; the first read comes off the refill path, the second off
  the array's registered output — two different word-select muxes, and
  the two merges are the design's only board coverage of the byte-strobe
  path. The word offset inside the line advances with the index so every
  word select is used, and the patterns deliberately avoid the
  `0xCAFE_xxxx` family `sdram_model` powers up holding: a CAFE pattern
  compares equal to untouched device content at index 0, so a wrong-word
  read would pass. A watchdog turns a stuck port into FAIL instead of a
  dark board.
  `fail_code_o` says which failure it was (wrong data vs. a port that
  stopped answering, split by port) and `fail_state_o` latches
  `cache_cntrl.dbg_state_o` — the miss FSM's state — at that instant, so a
  hang says WHERE it hung. On a board the LEDs are the only console there
  is. It also keeps the synthesizer from pruning the whole subsystem:
  without it nothing drives the request ports.
- `yarv32_cache.gprj`, `src/phys/yarv32_cache.cst` / `.sdc`, `impl/` —
  Gowin project (top `fpga_top`, `GW2AR-LV18QN88C8/I7`), pin constraints
  (clk PIN10, rst PIN88 active-high, LEDs 15-18; no SDRAM entries by
  design), timing constraints (25 MHz reference `clk25`, 50 MHz generated
  `clk_core`, false paths on reset and LEDs), and the `synth_check.tcl` /
  `pnr_check.tcl` wrappers + process config. Four places must agree on
  50 MHz: the rPLL parameters, the SDC generated clock, `-global_freq` in
  `pnr_check.tcl`, and `"Global_Freq"` in the process config (which is what
  a GUI run reads). `fpga_top`'s `CLK_FREQ_MHZ` is a fifth, and it is not a
  reporting knob: it sets the SDRAM refresh spacing.
- `src/rtl/dbg_uart_tx.sv`, `src/rtl/dbg_reporter.sv` — bring-up console:
  an 8N1 transmit-only UART (115200 on the board, into the onboard BL616
  USB bridge on PIN69) and a reporter that prints one status line per
  period, `"F0 G0 C0 D0 B1 I3 S4 L4 P4 M4 U3"` — fail code, BIST stage AT the failure,
  cache miss-FSM state at the failure, cache D-port bits at the failure,
  then the live BIST stage, live vector index, and `{0, busy, pass, fail}`.
  The live pair says where a running board is; the latched trio says where
  a failed one stopped, which the live pair cannot (by the time anyone
  reads it the stage is `S_DONE`). The last field, `V`, is `fpga_top`'s
  `BUILD_ID`: BUMP IT with every bitstream that changes behaviour, or two
  builds print identical lines and the board cannot say which fix is
  actually running. `A K R` are the accept counter and the live taps on
  the lookup-issue and macro-answer paths — `A` exists as a CONTROL: the
  skid slot cannot be occupied without an accept, so `A0` accuses the
  counter path itself rather than the design. Fields are sampled once at line start,
  so a line is one instant rather than a mix of several. `L P M U` are the
  D-cache event counters (`cache_cntrl.dbg_cnt_o`, saturating at F) in the
  order a request passes through them — lookups launched, tag answers seen,
  misses picked up by the FSM, misses unstalled: the first count that
  stopped advancing is the step that never happened, which a final-state
  snapshot cannot tell you. `E` repeats the D-port bits live and `W` is the
  handshake the BIST master sees (`{wready, rvalid, req.wvalid, we}`). On a
  watchdog failure the BIST does NOT return to `S_DONE`: it HOLDS the stage
  that hung, keeping its request asserted, so the live fields describe the
  stall instead of the recovery from it — without that hold, a latched
  "lookup launched" could sit next to a live lookup count of zero, two
  truths about two different instants. The LEDs carry a verdict; the
  UART is what carries several fields at once, which is what a hang needs.
  `fpga_top`'s `UART_BAUD` / `UART_PERIOD_W` parameters exist so the
  testbench can speed both up and read whole lines in a short run.
- `sim/bist_tb.sv` — testbench for `fpga_top` + `cache_bist` against
  `sdram_model` (`make bist`). Fails on a mismatch or on its own timeout,
  and decodes the debug UART so simulation prints the same status lines the
  board sends — the framing is proven before anything is flashed.
- `sim/sim_top.sv` — Verilator testbench / sim top (clock, reset, drives
  the I/D-cache ports with the yarv32-uc types, dumps `sim_top.vcd`).
  Compiles with `--timing`. Self-checking phases with PASS/FAIL counters,
  expected-`rdata` checks, and a watchdog: A (I-hit way 0), D (response
  held with `rready=0` + 2 outstanding I-port reads returned in order), E
  (I-hit on way 1 alone — per-way comparator + hit-way data mux), F
  (simultaneous I+D hits), B (I-miss), M (the B miss completes: unstall
  serves the refilled data, re-request hits), C (D-hit), H (D-miss with
  both ways valid), S (posted store hit, read-back, neighboring word
  untouched), S3/S4 (partial-strobe store hit, merged and
  neighbour-checked), V (dirty eviction with both ways valid: round-robin
  victim, writeback to the victim's address, evicted line survives the
  round-trip), V4 (store-miss write-allocate with a byte strobe merged
  into the refilled line), R (bootrom reads on each port — including the
  D port's high-half select at `addr[2]=1` — both ports at once through
  the arbiter, and a store to the ROM that must not stick), X (control
  register reset value, write, read-back), Y (a bypass load of an address
  whose cached copy is dirty — it must return what the DEVICE holds) and Z
  (bypass stores, full-word and partial-strobe, round-tripped through the
  device, then bypass cleared and the cached path checked again). The
  R/X/Y/Z phases handshake through the `d_access` (32-bit) / `i_load`
  (64-bit rdata) tasks instead of counting cycles, because they mix
  latencies that differ by two orders of magnitude. Preloads the tag/data
  macros by hierarchical reference
  (`u_dut.gen_way[w].u_itag.gen_store.mem` etc. — the `gen_store` level is
  `native_ram`'s `RAM_STYLE` generate, see above) at
  time 0, indexed by the plain set index (the DUT applies the
  `TAG_BYTES_W` shift itself).
- SDRAM power-up: `cache_cntrl` holds the controller in reset for
  `SDRAM_INIT_US` (200 us) after `rstn_i`. JEDEC SDRAM ignores every
  command until it has seen stable clock and NOPs for at least 100 us; the
  controller counts 15 cycles of its own (300 ns at 50 MHz), so without
  this hold the device never latches its mode register and every later
  access is undefined — invisible in simulation until the model started
  enforcing it (below).
- `sim/sdram_model.sv` — behavioral pin-level model of the GW2AR-18
  embedded SDRAM (32-bit data, CL=3, BL=1, auto-precharge via A10, row-open
  tracking per bank, MRS value check, 8 MiB backing array preloaded with
  `32'hCAFE0000 | word_index[15:0]`). The REAL `sdram_controller` RTL runs
  in the Verilator sim against it (the old `sdram_stub.sv` transactional
  stub, which merely mirrored the FSM's own placeholder encodings, is
  gone), so command encodings, ACT/precharge sequencing, and read timing
  are verified end-to-end. It also enforces the device's rules rather than
  just its data: no command but NOP inside the 100 us power-up window, no
  ACT/READ/WRITE before MRS, and tRP / tRFC / tRCD in nanoseconds (so the
  checks hold at any clock rate). Violations count into `protocol_errors`,
  which both testbenches treat as a failure.

## Protocol: the two CPU-facing ports

Custom native protocol, not AXI. Both ports are 1:1 with the yarv32-uc
core (rv32imac_zicsr_zifencei): type-identical to its `rv32_pkg`
typedefs, so the core connects struct-to-struct with no glue. See
`native_ram.sv` header comment for the memory-side timing of the same
handshake shape.

**I port** (`ifetch_req_t`/`ifetch_rsp_t`, 64-bit, read-only):

- Launch: `req.valid && rsp.ready` (note `ready`, not `wready` — the
  fetch port has no write path).
- Read response: `rsp.rvalid && req.rready`, held until consumed, 64-bit
  `rdata` (two 32-bit words, low word first).
- Up to 2 reads outstanding; responses always in request (accept) order —
  the fetch unit's in-flight-PC tracking relies on it (it needs its own
  depth-2 shadow FIFO for variable latency; the cache guarantees order,
  nothing more).
- Address is 8-byte aligned in steady state; the cache returns the
  aligned doubleword selected by `addr[4:3]` regardless of `addr[2]` —
  the core picks its half of `rdata`.

**D port** (`mem_req_t`/`mem_rsp_t`, 32-bit, single-outstanding):

- Launch: `req.wvalid && rsp.wready`.
- Read response: `rsp.rvalid && req.rready`, held until consumed,
  32-bit `rdata`. One unread response blocks new requests.
- Byte-strobed stores (`wstrb`), word-aligned addresses. Store commits
  at the accept cycle; no B channel (`bvalid` always low), posted-store
  semantics — the core retires stores at launch-accept.
- The core routes its MMIO (address bit 28) to its own AXI4-Lite master;
  such addresses never reach this port, and the cache does not decode
  bit 28.

## The reset chain needs a defined power-up state

`fpga_top`'s power-on reset starts with a counter that has no reset of its
own — nothing does, before it — so ITS power-up value decides whether the
fabric is reset at all. Powering up at all-ones makes `por_done` true from
the first instant, `rstn_raw` is high from the start, the synchroniser
never sees an edge, and NO reset pulse is ever produced. That is what the
board showed: a correctly clocked cache whose skid slot came up occupied,
so `wready` could never rise and no request was ever accepted. `por_cnt_q`
and `rstn_sync_q` therefore carry explicit initial values, and the Gowin
process config sets `"Initialize_Primitives": true` (with
`-init_primitives 1` in `pnr_check.tcl`) so the device honours them.

Debug probes have the same standing as the design here: the `T` field
first exported `tick_q[15:12]`, whose period divides the reporter's
sampling period exactly, so it always sampled the same phase and read
constant — indistinguishable from a dead clock, and it sent this
investigation down the wrong path for three board runs. Probe frequencies
must not be commensurate with the sampling period.

## Tag invalidation at reset

`cache_cntrl` walks every set after reset and writes `valid=0` into all
four tag macros (they are independent, so one set per cycle covers them
all), holding both ports' `wready` low for those `N_SETS` cycles. A cache
may not trust the state its tag memory wakes up in — and nothing here used
to clear it. RTL simulation passed only because Verilator reads an
uninitialised array as zero; the gate-level run (`make gatesim`, 4-state)
reads the same tags as X, the hit/miss decision becomes X, and the X
reaches the skid slot's valid bit and wedges the port on the first
request. That is the board's failure signature. Any testbench that
preloads the tag macros by hierarchical reference must do so AFTER
`tag_init_done`, or the sweep wipes the preload (`sim_top` waits for it).

Scope of that fix, measured rather than assumed: with the sweep disabled
and the RAMs filled with defined junk instead (`+RAM_GARBAGE`, see
`native_ram`), both testbenches still PASS — garbage tags merely cause
spurious misses and writebacks, which the design survives. So the sweep
closes a real hole (X propagation, and any device whose RAM wakes up
non-zero) but does NOT by itself explain the board hang, which remains
open.

## No unpacked arrays for state

Every register and control signal in `cache_cntrl` is a PACKED vector
(`logic [N_CACHE-1:0][N_SLOT-1:0] x`), never an unpacked array
(`logic x[N_CACHE][N_SLOT]`). Synthesis treats an unpacked array as a
MEMORY: yosys reported 51 of them here ("Replacing memory ... with list of
registers"), and it is free to implement one as LUT-RAM or BSRAM, which
has NO RESET. On the board that showed up as `slot_lookup_q` powering up
set, so `cache_lookup_go = skid_valid && !slot_lookup` never fired: the
D port accepted one request, launched no lookup, and wedged with `wready`
low — while simulation, where the array is just flops that reset, passed
every test. Packed vectors cannot be inferred as memory, so the two agree
by construction. The only intentional memories left are `native_ram.mem`
and the SDRAM model's array.

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

Per-port CPU access widths (the two ports differ): the I port fetches a
64-bit doubleword selected by `addr[NBIT_OFFSET-1:3]` (registered as
`cmp_dw_sel_q`), the D port moves one 32-bit word selected by
`addr[NBIT_OFFSET-1:2]` (registered as `dcmp_word_sel_q`). The internal
state is split to match — `iskid_q`/`rq_i_q` hold 64-bit I requests and
responses, `dskid_q`/`rq_d_q` hold 32-bit D ones, `miss_addr_q` is a
32-bit byte address — while all shared 1-bit control stays in
`[N_CACHE][...]` vectors so the per-cache loops survive. Addresses above
bit 23 are ignored by the region decode (see below), so a 32-bit CPU
address costs nothing extra.

Tag word layout: `rdata[0]=valid`, `rdata[1]=dirty`, `rdata[2+:TAG_FIELD_W]=tag`.

Two non-obvious details in this wiring:

- Tag macro addressing: `native_ram` drops the low `BYTES_W` bits of
  `addr` as a byte-select within the tag word (tag words are
  `TAG_DATA_W` ≥ 8 bits). `set_idx` must therefore be left-shifted by
  `TAG_BYTES_W` before being placed in `itag_req/dtag_req.addr`, or
  consecutive sets alias to the same tag word.
- Struct-to-struct port connections are packed-vector assignments (no
  strict type checking), so every width that appears on a native-protocol
  port must come from the same expansion as its counterpart —
  `way_req_t`/`way_rsp_t` for the data macros, `tag_req_t`/`tag_rsp_t`
  for the tag macros, `boot_req_t`/`boot_rsp_t` for the bootrom, and the
  hand-declared CPU pairs on the port side. Verilator `WIDTH` warnings
  are no longer waived in `sim/Makefile`, so a mismatched pair fails the
  build.

Set-associativity is implemented via a `generate for (w = 0; w < N_WAY; w++)`
loop instantiating `N_WAY` parallel `native_ram` macros for data and for
tags, both for I-cache and D-cache. Data macros are sized
`WAY_ADDR_W = CACHE_SIZE - $clog2(N_WAY)` (halved per doubling of ways, so
total capacity is unchanged). Tag macros are
`TAG_ADDR_W = NBIT_SET_IDX + TAG_BYTES_W` wide — one tag word per set
(`native_ram` decodes `word_addr = addr[TAG_ADDR_W-1:TAG_BYTES_W]` =
`set_idx`; a `NBIT_SET_IDX`-only `ADDR_W` would alias sets
`2**TAG_BYTES_W` apart onto one tag word — an elaboration-time Verilator
assert in `cache_cntrl` guards the depth). The tag lookup request (`set_idx`) is
broadcast to all ways in parallel; tag compare and hit detection are fully
parallel (`N_WAY` comparators per cache), not time-multiplexed.

## System address map (24 bit)

The SDRAM needs 23 address bits for its 8 MiB, so bit 23 is free and is
what separates memory from everything else. `yarv32_cache_pkg` holds the
map and the `yarv_region` decode (over the full 32-bit CPU address); only
bits `[23]` and `[12]` are looked at, so each peripheral aliases through
its 4 KiB window and address bits above 23 are ignored. (The core's own
MMIO window is address bit 28 — the core routes those accesses to its
AXI4-Lite master and they never reach the cache, which is why the map
does not decode it.)

| Range                 | Target                                     |
|-----------------------|--------------------------------------------|
| `0x00_0000-0x7F_FFFF` | SDRAM, 8 MiB, cached (or bypassed)         |
| `0x80_0000-0x80_07FF` | bootrom, 2 KiB, read-only, both CPU ports  |
| `0x80_1000`           | control register, 8 bit, read/write        |

The bootrom is a 2 KiB (`ADDR_W = BOOTROM_ADDR_W = 11`) read-only
`native_ram` instance holding the program a loader copies into SDRAM.
Both CPU ports reach it (the fetch side runs the boot code, the load side
reads the payload) and the macro has one port, so the two are arbitrated
with the D port winning ties — the same fixed priority the miss FSM uses;
the loser retries the next cycle. A store to the ROM region retires as a
posted no-op. A 32-bit D load returns HALF of the 64-bit bootrom word,
selected by `addr[2]` (low half when 0) — the bootrom macro is 64-bit
data, the D port's word select only reaches `addr[4:2]`, so the half is
picked at the response side, where the slot (and its address) is still
held. `cache_cntrl`'s `BOOTROM_FILE` parameter (forwarded from
`fpga_top`) is its `$readmemh` image; `sim/bootrom.hex` is the
simulation one, word *i* = `{32'hB0070000+i, 32'hC0DE0000+i}`.

The control register is `CSR_W` = 8 bits, byte 0 of the addressed
doubleword. Bit `CSR_BIT_BYPASS` (0) is CACHE_BYPASS: while it is set,
SDRAM loads and stores skip the cache arrays entirely and the miss FSM
moves the access straight to/from the device (`S_BP_*` states — one
32-bit word for a D access, two for a 64-bit I doubleword; a store word
that is not fully strobed is read-modify-written, because the controller
drives `dqm` itself and the pins cannot mask it). The rest of the
register is readable/writable scratch. Only the D port may write it —
the I port is read-only by spec, so a store there is dropped — and both
ports may read it. `CSR_RST_VAL` (default 0) is its power-on value.

Bypass is NOT a coherence mechanism: a line cached before the bit was set
stays cached and stale. It exists for the boot sequence, where a loader
must get a program into the DEVICE (not into a dirty D-cache line the
fetch side will never see) before jumping to it.

Requests are steered by a target decoded from the address AT ACCEPT and
frozen for the slot's lifetime (`slot_tgt_q`), so flipping CACHE_BYPASS
cannot re-route a request already in flight. Every non-cached target
(bootrom, register, bypass) is accepted only into an IDLE port and blocks
that port until it retires, which is what lets those paths ignore the
response queue's ordering machinery: while one is in flight there is
nothing else in flight to order it against. The cost is the I port's
second outstanding read for the duration of a bootrom fetch.

## Current state / known TODOs

Hit *detection* is combinational (parallel tag compare) and never enters
the FSM; only a miss triggers arbitration for the shared SDRAM controller
(dcache wins ties, fixed priority). The miss FSM is COMPLETE end-to-end
(TODO.md Phases 0–4 done): `S_IDLE` → `S_ARBITRATE` →
(`S_WB_READ`/`S_WB_XFER` if the victim is dirty) → `S_REFILL_XFER` →
`S_UPDATE_TAG` → `S_UNSTALL` → `S_IDLE`.
Victim selection prefers an invalid way, else per-set round-robin
(`rr_q`). Writeback streams the victim line straight off the data macro's
registered output to the victim's address `{victim_tag, set, offset}`.
`S_UPDATE_TAG` commits the refilled line (store-miss: write-allocate, the
store bytes merged in, committed dirty) and writes the way's tag in one
posted cycle; `S_UNSTALL` frees the missed skid slot, clears the queue
block flags and pushes the load response in accept order — the port no
longer wedges after a miss. D-cache store hits are posted writes through
the byte-strobe mux into the hit way plus a tag dirty-bit set. The SDRAM
side is the `sdram_controller` submodule (see Files), reached through
`sdram_line_port`: the `*_XFER` states (and the bypass path's `S_BP_READ`
/ `S_BP_WRITE`) issue ONE command and wait for its `done` pulse, so the
per-word enable/busy/rd_ready handshakes are the engine's business and
not the FSM's — no placeholder completion signals anywhere. Remaining
open items, marked `TODO` in source:

- The `gw2ar-32bit` submodule branch now lives on the fork
  `github.com/giacu92/sdram-controller` (`git submodule update --init`
  fetches it); the fork still has no LICENSE file.
- FPGA clocking decided: 50 MHz, single clock domain. `cache_cntrl` takes
  `CLK_FREQ_MHZ` (default 100 = the sim's clock) for the controller's
  refresh spacing, and forwards a new `sdram_clk_i` port to `sdram_clk_o`
  instead of tying it to `clk_i`; `fpga_top` drives it from the rPLL's
  phase-shifted CLKOUTP. The 180-degree shift is a bring-up starting point,
  not a measured optimum.
- The board build has never been run: synthesis, PnR and timing closure at
  50 MHz are the open Phase-6 items (TODO.md).
- The CPU-facing interface is 1:1 with the yarv32-uc core since Phase 10
  (TODO.md, 2026-09-06): two typed ports, 64-bit read-only I / 32-bit
  byte-strobed D, whole-struct skid copies per port. The 4-state
  gate-level check (`make gatesim`) and `make lint-yosys` have NOT been
  re-run against the new per-port datapaths (tools not installed;
  skipped by decision) — the split skid/queue state has only seen
  Verilator's 2-state zeroing, `--x-initial unique`, and
  `+RAM_GARBAGE`. Run them before trusting a board build.
- No boot image exists yet: `BOOTROM_FILE` defaults to `""` on the board
  build, and an uninitialised read-only array is a constant that
  GowinSynthesis may build as one (see `native_ram`'s `ram_style`
  comment). The macro itself is wired to both CPU ports.
- `cache_bist` does not exercise the bootrom, the control register or the
  bypass path — those are covered in `sim_top` (phases R/X/Y/Z) only, so
  the board self test still says nothing about them.

## Completion plan

**Superseded by `TODO.md`** (which folds the review findings from the
hashed-index "wip" commit into the phase order and adds the FPGA
build/bring-up phases for the Tang Nano 20K). The list below is kept for
reference; item numbering below is cited in older notes.

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

17. Delete dead code — mostly DONE, and partly wrong as written. The
    `offset`/`set_idx`/`tag` arrays are NOT dead: `offset[]` feeds
    `idw_sel`/`dword_sel`, `set_idx[]` feeds both tag requests, `tag[]`
    feeds `cmp_tag_q` (traced 2026-09-08). `cache_req_t`/`cache_rsp_t`/
    `CACHE_WIDTH` are gone; `native_ram`'s `REQ_ADDR_W` is now used, by
    the elaboration check on the request's addr width. What is left is the
    `ifdef VERILATOR` wave-trace mirror block at the end of `cache_cntrl`
    — it hand-copies two of roughly fourteen struct buses, so it is not a
    consistent facility, and current Verilator traces packed structs into
    VCD directly.
18. Collapse the duplicated I/D always_comb blocks and macro instantiations
    behind a generate-for over the two caches.
19. Make `sim/Makefile`'s `build` a stamped file target. (The Verilator
    waivers are gone — all five suppressed nothing by 2026-09-08 and were
    deleted; the sim builds clean with none. The stale sim_top phase
    comments were fixed in Phase 0.)

### Key context

The sim now runs the real controller RTL against a pin-level SDRAM model
(since the Phase-5 controller swap, 2026-09-02), so wrong command
encodings or protocol violations are caught in `make sim` — but the
testbench still has gaps: its settle loops key off hierarchical
`state_q`/`slot_miss_wait` taps, drive only sets 0/13/40/41/77, and use no
randomized traffic — TODO.md Phase 7 covers the BFM-based hardening and
cosim.

## Tooling

- Synthesis: Gowin EDA (`GowinSynthesis`), target `gw2ar18c-000`.
- Simulation: Verilator-compatible (`ifdef VERILATOR` assertions present
  in `native_ram.sv`); `$readmemh` used for INIT_FILE preload in sim.
- `.vo` files are post-place-and-route simulation netlists — read-only,
  do not hand-edit.