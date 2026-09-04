#!/usr/bin/env bash
#
# Pre-synthesis check with sv2v + yosys, for the errors that otherwise
# only show up on the Gowin host (gw_sh is not installed on this machine).
#
# What it catches:
#   - undriven nets: the EX1998 class ("net X does not have a driver").
#     `check -assert` fails the run on them.
#   - a BSRAM count estimate against the GW2AR-18's 46 blocks (RP0002).
#
# What it does NOT catch: yosys maps memories with its own rules, so its
# block count is an estimate of the DESIGN's needs, not a prediction of
# GowinSynthesis's mapping. In particular yosys reports the same 36 blocks
# whether native_ram uses byte write enables or not, while GowinSynthesis
# splits a byte-writable array into byte-wide blocks and needed 136. Treat
# a yosys count over the limit as a definite problem and a count under it
# as necessary, not sufficient.
#
# The rPLL is bypassed here (-DVERILATOR): it is a Gowin hard macro with no
# open-source model, and it is not what this check is about.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-${TMPDIR:-/tmp}/yarv32-yosys-check}"
BSRAM_LIMIT="${BSRAM_LIMIT:-46}"   # GW2AR-18

# Package first: the protocol structs are built by macros defined there.
SOURCES=(
    "$ROOT/src/rtl/pkg/yarv32_cache_pkg.sv"
    "$ROOT/src/rtl/native_ram.sv"
    "$ROOT/src/rtl/cache_cntrl.sv"
    "$ROOT/src/rtl/cache_bist.sv"
    "$ROOT/src/rtl/dbg_uart_tx.sv"
    "$ROOT/src/rtl/dbg_reporter.sv"
    "$ROOT/src/rtl/fpga_top.sv"
)
VERILOG_SOURCES=("$ROOT/src/ips/sdram-controller/rtl/sdram_controller.v")

for tool in sv2v yosys; do
    command -v "$tool" >/dev/null || { echo "$tool not on PATH"; exit 127; }
done

mkdir -p "$OUT"
sv2v -DVERILATOR -DNO_SIM_PLUSARGS --write="$OUT/design.v" "${SOURCES[@]}"

# Noise this check produces and why it is not acted on: sv2v renders the
# `parameter type REQ_T/RSP_T` ports at their DEFAULT width before yosys
# specializes each instance, so the unspecialized module elaboration warns
# about out-of-bounds range selects on mem_req_i/mem_rsp_o; and sv2v turns
# a `for (int b = ...)` loop variable inside always_comb into a block reg,
# which yosys reports as an inferred latch on `sv2v_autoblock_*.b`. Both
# are translation artifacts, not design defects — Verilator elaborates the
# same RTL clean, and GowinSynthesis reads the SystemVerilog directly.
echo "== yosys check (undriven nets, obvious structural problems) =="
if ! yosys -q -p "read_verilog $OUT/design.v ${VERILOG_SOURCES[*]}; \
                  hierarchy -top fpga_top; proc; check -assert" \
        > "$OUT/check.log" 2>&1; then
    grep -iE "no driver|multiple drivers|found and reported|ERROR" "$OUT/check.log" | head -20
    echo "FAIL: see $OUT/check.log"
    exit 1
fi
echo "OK   (no undriven nets; log: $OUT/check.log)"

echo "== yosys synth_gowin (BSRAM estimate) =="
yosys -p "read_verilog $OUT/design.v ${VERILOG_SOURCES[*]}; \
          synth_gowin -top fpga_top; stat" > "$OUT/synth.log" 2>&1 || {
    tail -20 "$OUT/synth.log"
    echo "FAIL: synthesis error, see $OUT/synth.log"
    exit 1
}

# Block-RAM primitives synth_gowin can emit.
BSRAM=$(awk '/^4\. Printing statistics/,0' "$OUT/synth.log" \
        | awk '$2 ~ /^(SP|SPX9|SDP|SDPX9B|SDPB|DP|DPX9B|DPB|pROM|pROMX9)$/ { n += $1 } END { print n+0 }')

echo "BSRAM blocks (yosys estimate): $BSRAM / $BSRAM_LIMIT"
if [ "$BSRAM" -gt "$BSRAM_LIMIT" ]; then
    echo "FAIL: over the device's BSRAM budget (GowinSynthesis RP0002)"
    exit 1
fi
echo "OK   (log: $OUT/synth.log)"
