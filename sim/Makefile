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

# Sources: package first, then RTL, then the sim-only stub + testbench.
# The SDRAM stub (sdram_stub.sv) defines SDRAM_Controller_HS_Top, which the
# DUT instantiates by name — it REPLACES the non-simulatable Gowin IP, so
# the real IP under src/ips/ is deliberately NOT on this list.
RTL_PKG   := ../src/rtl/pkg/yarv32_cache_pkg.sv
RTL       := ../src/rtl/native_ram.sv ../src/rtl/cache_cntrl.sv
SIM_RTL   := sdram_stub.sv sim_top.sv

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
             -Wno-UNOPTFLAT -Wno-INITIALDLY -Wno-MULTIDRIVEN \
             --top-module $(TOP) -Mdir obj_dir

.PHONY: run build wave clean

run: build
	$(VTOP) $(RUN_ARGS)

build:
	$(VERILATOR) $(VFLAGS) -o V$(TOP) $(RTL_PKG) $(RTL) $(SIM_RTL)

wave: run
	$(GTKWAVE) $(VCD)

clean:
	rm -rf obj_dir $(VCD)