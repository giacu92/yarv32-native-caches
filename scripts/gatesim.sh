#!/usr/bin/env bash
#
# Gate-level simulation of the synthesized design.
#
# Board bring-up hit a failure that simulation could not reproduce: the
# cache's flops behaved as if they never clocked, while the same RTL passed
# every test. RTL simulation cannot answer that question by construction —
# it never sees what synthesis built. This runs the SYNTHESIZED netlist
# (yosys synth_gowin, Gowin primitives, simulated with yosys's own cell
# models) against the same testbench, so a divergence between RTL and gates
# shows up here instead of on the bench.
#
# It is yosys's mapping, not GowinSynthesis's, so a pass does not clear the
# real toolchain — but a FAILURE is a real bug in the design or in the way
# it is written, reproducible locally in seconds.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-${TMPDIR:-/tmp}/yarv32-gatesim}"
YOSYS_DAT="${YOSYS_DAT:-$(yosys-config --datdir)}"
CELLS="$YOSYS_DAT/gowin/cells_sim.v"
# yosys leaves its internal tristate cell in the netlist once the I/O pads
# are gone, and ships no simulation model for it. Two lines cover it.
TBUF_MODEL_NAME="tbuf_model.v"

SOURCES=(
    "$ROOT/src/rtl/pkg/yarv32_cache_pkg.sv"
    "$ROOT/src/rtl/native_ram.sv"
    "$ROOT/src/rtl/sdram_line_port.sv"
    "$ROOT/src/rtl/cache_cntrl.sv"
    "$ROOT/src/rtl/cache_bist.sv"
    "$ROOT/src/rtl/dbg_uart_tx.sv"
    "$ROOT/src/rtl/dbg_reporter.sv"
    "$ROOT/src/rtl/fpga_top.sv"
)
VERILOG_SOURCES=("$ROOT/src/ips/sdram-controller/rtl/sdram_controller.v")

# Icarus rather than Verilator for the gate-level run: the netlist is full
# of tri-state nets and multi-hundred-character escaped identifiers, and
# Verilator hit an internal error on the latter ("String not in reverse
# hash map"). A 4-state simulator is the right tool for a netlist anyway —
# an undriven or contended net shows up as X instead of as a 0.
IVERILOG="${IVERILOG:-$(command -v iverilog || echo /home/giacomo/tools/oss-cad-suite/bin/iverilog)}"
VVP="${VVP:-$(command -v vvp || echo /home/giacomo/tools/oss-cad-suite/bin/vvp)}"

for tool in sv2v yosys; do
    command -v "$tool" >/dev/null || { echo "$tool not on PATH"; exit 127; }
done
[ -x "$IVERILOG" ] || { echo "iverilog not found (set IVERILOG=...)"; exit 127; }
[ -f "$CELLS" ] || { echo "Gowin cell models not found at $CELLS"; exit 1; }

# -nodsp: yosys otherwise maps a few adders onto MULT18X18, whose model
# lives in the extra-cell library and drags in the rest of the hard-block
# zoo. This design has no multipliers to speak of, so keeping them out of
# the netlist costs nothing and keeps the gate-level build small.
#
# -noiopads (IOPAD_OPT): the IOBUF model in yosys's own cell library
# assigns to its input port, which Verilator rejects outright. Pin buffers
# are not what a gate-level run is checking anyway — the logic behind them
# is. Set IOPAD_OPT= (empty) to keep them: Icarus accepts that model, and
# it avoids yosys's own tri-state cell, which has crashed iverilog.

mkdir -p "$OUT"

# A synthesized netlist has no parameters, so the testbench cannot override
# UART_BAUD / UART_PERIOD_W the way it does in RTL. The defines below bake
# the fast simulation values in before synthesis, and the testbench copy
# drops the override — same stimulus, same checks, no parameter ports.
sv2v -DVERILATOR -DGATESIM -DNO_SIM_PLUSARGS --write="$OUT/design.v" "${SOURCES[@]}"

python3 - "$ROOT/sim/bist_tb.sv" "$OUT/gate_tb.sv" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
# Drop the parameter override block: "fpga_top #( .X(..), .Y(..) ) u_dut ("
text = re.sub(r"fpga_top\s*#\(.*?\)\s*u_dut\s*\(", "fpga_top u_dut (", text, flags=re.S)
# The RTL hierarchy is gone in a flattened netlist, so the one hierarchical
# probe has to go too. It only decorates the failure message; the pass/fail
# verdict comes from the pins.
text = text.replace("u_dut.u_bist.fail_state_q", "4'd0")
open(dst, "w").write(text)
PYEOF

# Synthesis is the slow part (minutes). Reuse the netlist when it is newer
# than every source, so iterating on the testbench costs seconds.
if [ "${FORCE_SYNTH:-0}" = "1" ] || [ ! -f "$OUT/netlist.v" ] || \
   [ "$OUT/design.v" -nt "$OUT/netlist.v" ]; then
    echo "== synthesis (yosys synth_gowin) =="
    # SYNTH_OPTS lets a run disable individual mappings (-nobram,
    # -nolutram, -noalu, -nodffe ...). The gate-level sim reproduces a
    # failure the RTL sim does not, so bisecting the mapping that causes it
    # is the fastest way from "gates differ" to "this construct differs".
    yosys -q -p "read_verilog $OUT/design.v ${VERILOG_SOURCES[*]}; \
                 synth_gowin -nodsp ${IOPAD_OPT:--noiopads} ${SYNTH_OPTS:-} -top fpga_top; \
                 write_verilog -noattr $OUT/netlist.v"
else
    echo "== synthesis skipped (netlist up to date; FORCE_SYNTH=1 to redo) =="
fi

cat > "$OUT/$TBUF_MODEL_NAME" <<'TBUFEOF'
module \$_TBUF_ (
    input  A,
    input  E,
    output Y
);
    assign Y = E ? A : 1'bz;
endmodule
TBUFEOF

echo "== gate-level run =="
# The netlist drives the same testbench as the RTL sim, so a divergence is
# a divergence in the design, not in the stimulus.
"$IVERILOG" -g2012 -s bist_tb -o "$OUT/gate.vvp" \
    "$CELLS" "$OUT/$TBUF_MODEL_NAME" "$OUT/netlist.v" \
    "$ROOT/sim/sdram_model.sv" "$OUT/gate_tb.sv" \
    > "$OUT/build.log" 2>&1 || { tail -25 "$OUT/build.log"; echo "FAIL: build"; exit 1; }

# Run from $OUT so the testbench's VCD lands next to the netlist rather
# than in the repository.
(cd "$OUT" && "$VVP" "$OUT/gate.vvp")
echo "waves: $OUT/bist_tb.vcd"
