# Top-level Makefile for code formatting (Verible).
#
# The FPGA build still runs through the Gowin IDE / gw_sh (see CLAUDE.md);
# this Makefile covers formatting and delegates simulation targets to
# sim/Makefile.
#
#   make format        reformat every SystemVerilog file in place
#   make format-check  fail (exit 1) if any file is not formatted
#   make format-diff   show a unified diff of what `make format` would do
#   make sim           build + run the Verilator sim
#   make wave          build + run the sim, then open the VCD in gtkwave
#   make clean         delegate to sim/Makefile
#   make run           delegate to sim/Makefile
#
# Requires `verible-verilog-format` on PATH.
# `make sim` / `make wave` additionally require `verilator` and `gtkwave`.

VERIBLE       ?= verible-verilog-format
FLAGFILE      := verible.flags

# SystemVerilog sources to format: all RTL under src/rtl plus the sim
# wrapper. Build artefacts (sim/obj_dir) and generated files are excluded.
SV_SOURCES    := $(shell find src/rtl sim -type f \( -name '*.sv' -o -name '*.svh' -o -name '*.v' \) \
                       ! -path 'sim/obj_dir/*' 2>/dev/null)

# Formatter invocation shared by all targets.
FMT_FLAGS     := --flagfile=$(FLAGFILE)

# GTKWave binary for `make wave`.
GTKWAVE       ?= gtkwave

# VCD written by the sim.
SIM_VCD       := sim/sim_top.vcd

.PHONY: format format-check format-diff sim bist lint-fpga lint-yosys gatesim wave help clean \
        run sw sw-run cosim fpga-synth fpga-pnr fpga

help:
	@echo "Targets:"
	@echo "  format        reformat all SystemVerilog in place"
	@echo "  format-check  exit 1 if any file is unformatted (CI/pre-commit)"
	@echo "  format-diff   print a unified diff of pending formatting changes"
	@echo "  sim           build + run the Verilator sim"
	@echo "  bist          build + run the FPGA board-top self test sim"
	@echo "  lint-fpga     elaborate + lint fpga_top (no Gowin tools needed)"
	@echo "  lint-yosys    sv2v+yosys: undriven nets + BSRAM budget check"
	@echo "  gatesim       gate-level sim of the synthesized netlist (4-state)"
	@echo "  fpga          Gowin synthesis + place & route (needs gw_sh)"
	@echo "  wave          build + run the sim, then open the VCD in gtkwave"
	@echo "  run           build + run the Verilator sim"
	@echo "  clean         remove simulation build artefacts + waveforms"
	@echo "  sw            build the quicksort C program -> sim/sw/quicksort/build/{imem,dmem}.hex"
	@echo "  sw-run        build the C program and run the sim loading it"
	@echo "  cosim         build Spike + sw, run both, diff vs golden Spike"
	@echo ""
	@echo "Variables:"
	@echo "  VERIBLE=$(VERIBLE)   formatter binary"
	@echo "  FLAGFILE=$(FLAGFILE)   project formatter policy"
	@echo "  GTKWAVE=$(GTKWAVE)   waveform viewer binary"

# Reformat in place.
format: $(SV_SOURCES)
	@for f in $(SV_SOURCES); do \
	    $(VERIBLE) $(FMT_FLAGS) --inplace "$$f" || exit 1; \
	done
	@echo "formatted $(words $(SV_SOURCES)) files"

# Dry run: list files that would change. Exits 1 if any do (CI-friendly).
format-check: $(SV_SOURCES)
	@status=0; \
	for f in $(SV_SOURCES); do \
	    if ! $(VERIBLE) $(FMT_FLAGS) "$$f" 2>/dev/null | diff -q "$$f" - >/dev/null 2>&1; then \
	        echo "not formatted: $$f"; \
	        status=1; \
	    fi; \
	done; \
	exit $$status

# Dry run: show the full diff.
format-diff: $(SV_SOURCES)
	@for f in $(SV_SOURCES); do \
	    $(VERIBLE) $(FMT_FLAGS) "$$f" 2>/dev/null | diff -u "$$f" - || true; \
	done

# Build + run the Verilator simulation.
sim:
	$(MAKE) -C sim run

# Build + run the FPGA board-top self test (fpga_top + cache_bist against
# the SDRAM model): the same traffic the Tang Nano 20K bitstream runs.
bist:
	$(MAKE) -C sim bist

# Elaborate + lint the FPGA wrapper. Runs without the Gowin toolchain.
lint-fpga:
	$(MAKE) -C sim lint-fpga

# Pre-synthesis check with sv2v + yosys: fails on undriven nets (the Gowin
# EX1998 class) and reports a BSRAM count against the device's 46 blocks
# (RP0002). Needs sv2v and yosys, neither of which is the Gowin toolchain
# — see the header of the script for what this does and does not predict.
lint-yosys:
	./scripts/yosys_check.sh

# Gate-level simulation of the synthesized netlist (yosys + Icarus). Runs
# the same BIST testbench the RTL sim runs, in 4-state, so a construct that
# behaves differently after synthesis shows up here instead of on the
# bench. See the header of scripts/gatesim.sh.
gatesim:
	./scripts/gatesim.sh

# Open the waveforms. A fresh simulation is run first.
wave: sim
	$(GTKWAVE) $(SIM_VCD)

# ----------------------------------------------------------------------
# Simulation target delegation
# ----------------------------------------------------------------------
#
# Delegate the sim-only targets to sim/Makefile (explicit, not a catch-all
# `%:` rule, so unknown/typo targets fail at the root with a clear "No
# rule to make target" instead of being silently forwarded into sim/).
#
# sim/cosim and sim/sw trees do not exist yet (TODO.md Phase 7); guard the
# delegations with $(wildcard) so `make clean` works without them.
COSIM_CLEAN := $(patsubst %/Makefile,%,$(wildcard sim/cosim/*/Makefile))

clean:
	$(MAKE) -C sim clean
	@for d in $(COSIM_CLEAN); do $(MAKE) -C $$d clean || exit 1; done

run:
	$(MAKE) -C sim run


# ----------------------------------------------------------------------
# C program -> Harvard imem.hex + dmem.hex (rv32imac toolchain)
# ----------------------------------------------------------------------
#
# Build (and optionally run) a C program for the Harvard sim. `sw`
# compiles sim/sw/quicksort/main.c with the prebuilt riscv32-esp-elf-gcc and links
# across two 0-based regions (link.ld): .text -> IMEM, .data -> DMEM,
# producing a $readmemh word hex for each. `sw-run` then runs the sim
# loading both images via +IINIT/+DINIT instead of the hand-crafted
# imem.hex/dmem.hex oracle.
#
# `make -C sim/sw` builds every program and test oracle at once; this target
# builds only quicksort (what sw-run needs).
#
sw:
	$(MAKE) -C sim/sw/quicksort

sw-run: sw
	$(MAKE) -C sim run RUN_ARGS="+IINIT=sw/quicksort/build/imem.hex +DINIT=sw/quicksort/build/dmem.hex"

# ----------------------------------------------------------------------
# Co-sim: RTL vs Spike (golden ISA reference)
# ----------------------------------------------------------------------
#
# Build (once) a local Spike with commit logging, build the C program,
# run it on both Spike and the Verilator sim, and diff per-retire pc +
# register writes. First run needs Spike build deps (see
# sim/cosim/build_spike.sh). Delegated to sim/cosim/quicksort/Makefile.
#
cosim:
	$(MAKE) -C sim/cosim/quicksort cosim

# ----------------------------------------------------------------------
# FPGA build (Gowin EDA, Tang Nano 20K)
# ----------------------------------------------------------------------
#
# Bitstream flow for `yarv32_cache.gprj` (top module `fpga_top`, device
# GW2AR-LV18QN88C8/I7). Both steps go through the Tcl wrappers in impl/,
# not through `gw_sh -pnr -do ...` (not a valid flow in V1.9.11.03).
#
# gw_sh is NOT on this machine — it lives on the Gowin host (see CLAUDE.md).
# Point GW_SH at the binary, or rsync the tree over and run there:
#
#   make fpga GW_SH=/home/giacomo/gowin_ide/IDE/bin/gw_sh
#
# The Qt variables keep the headless invocation from trying to open a GUI.
# Both steps silently no-op if their outputs already exist, so each target
# deletes its output directory first.
#
GW_SH     ?= gw_sh
GW_ENV    := QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1

fpga-synth:
	rm -rf impl/gwsynthesis
	$(GW_ENV) $(GW_SH) impl/synth_check.tcl

fpga-pnr:
	rm -rf impl/pnr
	$(GW_ENV) $(GW_SH) impl/pnr_check.tcl

fpga: fpga-synth fpga-pnr
