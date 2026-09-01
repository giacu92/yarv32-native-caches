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