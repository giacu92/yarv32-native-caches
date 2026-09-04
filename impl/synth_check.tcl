# Gowin synthesis run for the yarv32 cache subsystem.
#
#   gw_sh impl/synth_check.tcl
#
# The project path is derived from this script's own location, so the tree
# can be rsync'd anywhere on the machine that has the Gowin toolchain and
# still build (no hardcoded /home/... path).
#
# Gotcha: gw_sh silently no-ops if the outputs (.vg / report) already exist
# — delete impl/gwsynthesis/ before re-running after an RTL change.
set proj_dir [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $proj_dir yarv32_cache.gprj]
set_option -top_module fpga_top
set_option -verilog_std sysv2017
run syn
