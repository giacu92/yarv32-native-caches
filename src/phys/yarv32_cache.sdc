# =============================================================================
# SDC — timing constraints for the yarv32 cache subsystem on the Tang Nano 20K
#
# Target board:  Sipeed Tang Nano 20k (GW2AR-LV18QN88C8/I7, QFN88)
# Primary clock: 25 MHz single-ended reference from the MS5351M clock
#   generator (crystal-fed; CLK0 on PIN10, LVCMOS33).
#
# The SDC must be a <File type="file.sdc"> entry in the .gprj — merely
# naming it from impl/pnr/cmd.do is not enough, PnR then falls back to an
# unconstrained 100 MHz and reports timing for a design that does not ship.
#
# Gowin's SDC subset supports create_clock / create_generated_clock /
# set_input_delay / set_output_delay / set_false_path / set_multicycle_path.
# Keep it to those.
# =============================================================================

# Primary clock: 25 MHz reference on clk_i (PIN10). Period = 40 ns.
create_clock -name clk25 -period 40 [get_ports {clk_i}]

# Core clock: rPLL CLKOUT = clk_i * 10 / 5 = 50 MHz, period 20 ns.
# THREE places must agree or the reports constrain something the design does
# not run at: the rPLL parameters in fpga_top (IDIV_SEL=4 / FBDIV_SEL=9 /
# ODIV_SEL=16), this constraint, and -global_freq in impl/pnr_check.tcl
# (mirrored by "Global_Freq" in the process config, which is what a GUI run
# reads). fpga_top's CLK_FREQ_MHZ is a fourth: it sets the SDRAM refresh
# spacing, so a stale value under-refreshes the chip rather than mis-reporting
# timing.
create_generated_clock -name clk_core -source [get_ports {clk_i}] -master_clock clk25 -multiply_by 10 -divide_by 5 [get_nets {clk_core}]

# SDRAM clock: the same rPLL's CLKOUTP, phase shifted by PSDA_SEL (180 deg
# at bring-up). It is deliberately NOT constrained here.
#
# An explicit create_generated_clock on it was rejected with TA2003
# ("Can't set timing constraint to object sdram_clk") followed by TA1052
# ("Generated clock is ignored"): the net drives nothing but the
# O_sdram_clk pin, so it does not survive as a constrainable object.
# Nothing is lost — Gowin auto-derives a clock on the rPLL output, and no
# fabric logic runs on it (all the cache logic is on clk_core), so there
# are no internal paths for it to constrain. The SDRAM's own setup/hold
# against this edge is an off-die property of the SIP wiring, tuned with
# PSDA_SEL, not with an SDC statement.

# Async reset: the board button S1 (active high on this board) has no launch
# clock. fpga_top synchronizes its deassertion to clk_core.
set_false_path -from [get_ports {rst_i}]

# Debug UART TX: a 115200 baud line, four orders of magnitude slower than
# the clock, and nothing on the board latches it against clk_core.
set_false_path -to [get_ports {uart_txd_o}]

# Status LEDs are not timing critical (human eye).
set_false_path -to [get_ports {led_o[*]}]

# Single clock domain: cache_cntrl, cache_bist, the tag/data BSRAM macros and
# the SDRAM controller all run on clk_core. clk_i (clk25) only feeds the rPLL,
# and sdram_clk leaves the die on O_sdram_clk — there is no user logic on
# either, so there is no crossing to cut.
