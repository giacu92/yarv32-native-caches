`resetall
`timescale 1ns / 1ps
`default_nettype none

/**
 * Periodic verdict line over the debug UART.
 *
 * One line every 2**PERIOD_W clocks, and what it says depends on the
 * verdict:
 *
 *   pass_i : "PASS\r\n"
 *   fail_i : "FAIL F0 C0 B1 I3 S4\r\n" — the verdict plus one labelled
 *            hex nibble per field, the whole debug log
 *   neither: nothing at all, the line is suppressed
 *
 * The asymmetry is the point. A passing board has nothing to say beyond
 * that it passed, and 18 hex fields to read every time it does is 18
 * chances to misread one. A FAILING board is the opposite case: the fields
 * are the only console there is, they cannot be recovered later, and the
 * fail state is held (see cache_bist's hang hold) so the line describes
 * the stall rather than the recovery from it.
 *
 * Suppressing the line while the test runs means a board that wedges
 * WITHOUT tripping a watchdog says nothing, where the old unconditional
 * line at least proved the clock and the UART were alive. The watchdogs
 * are what covers that: a stuck port becomes fail_i, not silence. The
 * heartbeat LED is the other half of the answer.
 *
 * Fields are sampled once, at line start, so a line is one instant rather
 * than a mix of several. Field labels are a parameter so the caller names
 * its own fields; the count is fixed by the width of `fields_i` (4 bits
 * each).
 *
 * Naming: ports use *_i/_o; internals no prefix; flops _q.
 */

module dbg_reporter #(
    // Number of 4-bit fields on the line.
    parameter int N_FIELD = 5,
    // Field labels as one string literal, left to right: "FCBIS" labels
    // field 0 'F', field 1 'C' and so on. A fixed-width packed parameter
    // rather than an unpacked array sized by N_FIELD, because the array
    // bound would be elaborated against the DEFAULT N_FIELD and reject a
    // longer label list at instantiation. Up to 32 fields (256 bits); the
    // literal is right-aligned, which the index below accounts for.
    parameter logic [255:0] LABELS = "FCBIS",
    // Line period: 2**PERIOD_W clocks (24 -> ~0.34 s at 50 MHz).
    parameter int PERIOD_W = 24
) (
    input wire clk_i,
    input wire rstn_i,

    input wire [4*N_FIELD-1:0] fields_i,

    // Verdict. Both low suppresses the line entirely; fail_i wins if the
    // caller ever raises both, because a failure is the reportable event.
    input wire pass_i,
    input wire fail_i,

    output wire       tx_valid_o,
    input  wire       tx_ready_i,
    output wire [7:0] tx_data_o
);

    // "PASS" / "FAIL" is VERB_LEN bytes; a fail line then adds a space,
    // 3 bytes per field ("X0 "), and CR LF. A pass line is just the verb
    // and CR LF.
    localparam int VERB_LEN = 4;
    localparam int LEN_PASS = VERB_LEN + 2;
    localparam int LEN_FAIL = VERB_LEN + 1 + 3 * N_FIELD + 2;
    // Longest line, and also the idle sentinel for idx_q: it is >= either
    // line length, so idx_q = LINE_MAX is "not sending" whichever verdict
    // was last latched.
    localparam int LINE_MAX = LEN_FAIL;

`ifdef VERILATOR
    initial begin
        assert (N_FIELD <= 32)
        else $fatal(1, "dbg_reporter: N_FIELD (%0d) exceeds the 32 LABELS fit", N_FIELD);
    end
`endif
    localparam int IDX_W = $clog2(LINE_MAX + 1);

    // Fields are sampled once, when the line starts. Sampling them per
    // character would mix instants inside one line — a field printed
    // before an event and the next field after it — which reads as an
    // impossible state (observed in simulation: a zero fail code next to a
    // populated post-mortem field).
    logic [4*N_FIELD-1:0] fields_q;
    // Which line is being sent. Latched with the fields, so a verdict that
    // changes mid-line cannot re-length the line under way.
    logic                 fail_q;

    logic [ PERIOD_W-1:0] period_q;
    logic [    IDX_W-1:0] idx_q;  // LINE_MAX = idle (line finished)

    wire  [    IDX_W-1:0] line_len = IDX_W'(fail_q ? LEN_FAIL : LEN_PASS);
    wire                  sending = (idx_q < line_len);

    function automatic logic [7:0] hex_digit(input logic [3:0] v);
        hex_digit = (v < 10) ? (8'h30 + 8'(v)) : (8'h41 + 8'(v) - 8'd10);
    endfunction

    // Byte at position idx of the line. The verb occupies [0, VERB_LEN);
    // a fail line then has a separating space and the fields, indexed from
    // VERB_LEN + 1.
    function automatic logic [7:0] line_byte(input logic [IDX_W-1:0] idx);
        int field, sub, rel;
        logic [8*VERB_LEN-1:0] verb;
        verb = fail_q ? "FAIL" : "PASS";
        if (idx < IDX_W'(VERB_LEN)) line_byte = verb[8*(VERB_LEN-1-int'(idx))+:8];
        else if (idx == line_len - IDX_W'(2)) line_byte = 8'h0D;  // CR
        else if (idx == line_len - IDX_W'(1)) line_byte = 8'h0A;  // LF
        else if (idx == IDX_W'(VERB_LEN)) line_byte = 8'h20;  // "FAIL " separator
        else begin
            rel   = int'(idx) - (VERB_LEN + 1);
            field = rel / 3;
            sub   = rel % 3;
            case (sub)
                0: line_byte = LABELS[8*(N_FIELD-1-field)+:8];
                1: line_byte = hex_digit(fields_q[4*field+:4]);
                default: line_byte = 8'h20;  // space
            endcase
        end
    endfunction

    assign tx_valid_o = sending;
    assign tx_data_o  = line_byte(idx_q);

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            period_q <= '0;
            idx_q    <= IDX_W'(LINE_MAX);
            fields_q <= '0;
            fail_q   <= 1'b0;
        end else begin
            period_q <= period_q + 1'b1;
            if (sending) begin
                if (tx_ready_i) begin
                    // Park on the sentinel rather than one past the end:
                    // a pass line ends below LINE_MAX, and leaving idx_q
                    // there would make the next latched verdict resume a
                    // line that had already finished.
                    idx_q <= (idx_q == line_len - IDX_W'(1)) ? IDX_W'(LINE_MAX) : idx_q + 1'b1;
                end
            end else if (&period_q && (pass_i || fail_i)) begin
                idx_q    <= '0;
                fields_q <= fields_i;
                fail_q   <= fail_i;
            end
        end
    end

endmodule

`resetall
