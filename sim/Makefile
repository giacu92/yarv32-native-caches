# sim/Makefile — Verilator build + run for the yarv32 cache subsystem.
#
# Invoked from the top-level Makefile via `$(MAKE) -C sim run|clean`.
# Targets:
#   make run    build (if needed) and run the sim, writing sim_top.vcd
#   make build  Verilator compile only
#   make wave   run, then open sim_top.vcd in gtkwave
#   make clean  remove obj_dir/ and the VCD
#
# Requires `verilator` (>= 5.x, for --timing). `make wave` also needs gtkwave.
# RUN_ARGS is passed through to the sim binary (e.g. +IINIT=... +DINIT=...).

VERILATOR ?= verilator
GTKWAVE   ?= gtkwave

TOP       := sim_top
VTOP      := obj_dir/V$(TOP)
VCD       := sim_top.vcd

# Sources: package first, then RTL, then the SDRAM controller (git
# submodule, gw2ar-32bit branch — 32-bit adaptation of
# github.com/stffrdhrn/sdram-controller), the behavioral SDRAM chip model,
# and the testbench. The controller is real RTL driven on the raw SDRAM
# pins, so the sim exercises the actual command encoding end-to-end.
RTL_PKG   := ../src/rtl/pkg/yarv32_cache_pkg.sv
RTL       := ../src/rtl/native_ram.sv ../src/rtl/cache_cntrl.sv \
             ../src/ips/sdram-controller/rtl/sdram_controller.v
SIM_RTL   := sdram_model.sv sim_top.sv

# FPGA board top + its bring-up self test. Built as a second sim
# (`make bist`) that runs exactly what the Tang Nano 20K bitstream runs:
# fpga_top (rPLL bypassed under Verilator) driving cache_bist against the
# real controller and the SDRAM model.
FPGA_RTL  := ../src/rtl/cache_bist.sv ../src/rtl/dbg_uart_tx.sv \
             ../src/rtl/dbg_reporter.sv ../src/rtl/fpga_top.sv
BIST_TOP  := bist_tb
VBIST     := obj_bist/V$(BIST_TOP)
BIST_VCD  := bist_tb.vcd

# --timing: enable # delays / event waits in the testbench.
# --trace : enable $dumpfile/$dumpvars VCD output.
# Warnings silenced: unused signals (skeleton FSM TODO gaps), incomplete
# case, combinational-loop false-positives on the struct-array tag path,
# and the initial-block-for-clocks pattern. Width truncation/expansion are
# NOT silenced any more: the parametrizable mem/cache/tag struct pair
# (yarv32_cache_pkg macros) keeps port widths matched by construction, so
# a width warning now means a real bug.
VFLAGS    := --binary --timing --trace \
             -Wno-UNUSED -Wno-CASEINCOMPLETE \
             -Wno-UNOPTFLAT -Wno-INITIALDLY -Wno-MULTIDRIVEN

# X-initial variants: Verilator reads uninitialised state as zero, which is
# exactly how a missing reset hides. --x-initial unique gives every
# uninitialised variable a random value per run instead, so state the design
# forgot to clear stops behaving like a convenient zero. This is what makes
# a bug like "the tag RAMs are never invalidated" fail in RTL, without
# needing a gate-level netlist.
XFLAGS    := --x-initial unique --x-assign unique

.PHONY: run build wave bist bist-build xrun xbist lint-fpga clean

run: build
	$(VTOP) $(RUN_ARGS)

build:
	$(VERILATOR) $(VFLAGS) --top-module $(TOP) -Mdir obj_dir -o V$(TOP) \
	    $(RTL_PKG) $(RTL) $(SIM_RTL)

wave: run
	$(GTKWAVE) $(VCD)

# Board-top self test: passes (exit 0) only if the BIST reaches its PASS
# state before the testbench watchdog fires.
bist: bist-build
	$(VBIST)

bist-build:
	$(VERILATOR) $(VFLAGS) --top-module $(BIST_TOP) -Mdir obj_bist -o V$(BIST_TOP) \
	    $(RTL_PKG) $(RTL) $(FPGA_RTL) sdram_model.sv $(BIST_TOP).sv

# Same two simulations, with uninitialised state randomised (see XFLAGS).
xrun:
	$(VERILATOR) $(VFLAGS) $(XFLAGS) --top-module $(TOP) -Mdir obj_xdir -o V$(TOP)_x \
	    $(RTL_PKG) $(RTL) $(SIM_RTL)
	obj_xdir/V$(TOP)_x

xbist:
	$(VERILATOR) $(VFLAGS) $(XFLAGS) --top-module $(BIST_TOP) -Mdir obj_xbist \
	    -o V$(BIST_TOP)_x $(RTL_PKG) $(RTL) $(FPGA_RTL) sdram_model.sv $(BIST_TOP).sv
	obj_xbist/V$(BIST_TOP)_x

# Elaborate + lint the FPGA wrapper without running anything. Cheap gate
# for the board build on a machine without the Gowin toolchain (the rPLL
# hard macro is bypassed under `VERILATOR`).
lint-fpga:
	$(VERILATOR) --lint-only -Wno-UNUSED -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
	    -Wno-MULTIDRIVEN --top-module fpga_top $(RTL_PKG) $(RTL) $(FPGA_RTL)

clean:
	rm -rf obj_dir obj_bist obj_xdir obj_xbist $(VCD) $(BIST_VCD)