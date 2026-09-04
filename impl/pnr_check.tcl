# Gowin place & route for the yarv32 cache subsystem. Run after synthesis:
#
#   gw_sh impl/pnr_check.tcl
#
# `# Register power-up values. The design's reset chain starts with a counter
# that has no reset of its own, so its power-up value decides whether the
# fabric is reset at all — see the POR comment in fpga_top. Without this,
# those flops come up undefined and a board can run with no reset ever.
set_option -init_primitives 1

run pnr` takes the options set here (and those persisted in the project);
# impl/pnr/cmd.do is an OUTPUT it overwrites, not an input, so editing that
# file changes nothing. `gw_sh -pnr -do <file>` is not a valid flow in
# V1.9.11.03 — this Tcl wrapper is the working CLI path. It also no-ops if
# the outputs already exist; delete impl/pnr/ before re-running.
set proj_dir [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $proj_dir yarv32_cache.gprj]
set_option -top_module fpga_top

# Target frequency for the timing engine. MUST match the SDC's clk_core
# (50 MHz) and fpga_top's rPLL settings — see the header of
# src/phys/yarv32_cache.sdc for the full list of places that have to agree.
set_option -global_freq 50.000

# Algorithm SELECTORS, not effort levels (and they do not mean the same
# thing on both options):
#   -place_option  0 = compile speed (default), 1 = routability, 2 = timing
#   -route_option  0 = congestion (default),    1 = timing,      2 = speed
# The timing-priority pair is 2 / 1.
set_option -place_option 2
set_option -route_option 1

# Per-path (cell-by-cell) timing detail. Without it the run writes only the
# summary; the breakdown that says where a failing path spends its time goes
# to the plain-text report (impl/pnr/*.tr.txt + *.timing_paths).
set_option -gen_text_timing_rpt 1

# Register power-up values. The design's reset chain starts with a counter
# that has no reset of its own, so its power-up value decides whether the
# fabric is reset at all — see the POR comment in fpga_top. Without this,
# those flops come up undefined and a board can run with no reset ever.
set_option -init_primitives 1

run pnr
