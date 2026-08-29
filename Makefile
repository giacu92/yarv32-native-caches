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

.PHONY: format format-check format-diff sim wave help clean run sw sw-run cosim

help:
	@echo "Targets:"
	@echo "  format        reformat all SystemVerilog in place"
	@echo "  format-check  exit 1 if any file is unformatted (CI/pre-commit)"
	@echo "  format-diff   print a unified diff of pending formatting changes"
	@echo "  sim           build + run the Verilator sim"
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
clean:
	$(MAKE) -C sim clean
	$(MAKE) -C sim/cosim/quicksort clean
	$(MAKE) -C sim/cosim/ecall clean

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
