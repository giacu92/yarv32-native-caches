`resetall
`timescale 1ns / 1ps
`default_nettype none

/**
 * Periodic one-line status report over the debug UART.
 *
 * Prints "F0 C0 B1 I3 S4\r\n": one labelled hex nibble per field, every
 * 2**PERIOD_W clocks. The fields are sampled live, not latched, so the
 * line shows what the design is doing RIGHT NOW — which is the whole
 * point: a board that hangs prints the same line forever, and the line
 * says which state it is stuck in. LEDs can carry a verdict; only this can
 * carry several fields at once without an encoding to decipher.
 *
 * Field labels are a parameter so the caller names its own fields; the
 * count is fixed by the width of `fields_i` (4 bits each).
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

    output wire       tx_valid_o,
    input  wire       tx_ready_i,
    output wire [7:0] tx_data_o
);

    // 3 bytes per field ("X0 ") plus CR LF.
    localparam int LINE_LEN = 3 * N_FIELD + 2;

`ifdef VERILATOR
    initial begin
        assert (N_FIELD <= 32)
        else $fatal(1, "dbg_reporter: N_FIELD (%0d) exceeds the 32 LABELS fit", N_FIELD);
    end
`endif
    localparam int IDX_W = $clog2(LINE_LEN + 1);

    // Fields are sampled once, when the line starts. Sampling them per
    // character would mix instants inside one line — a field printed
    // before an event and the next field after it — which reads as an
    // impossible state (observed in simulation: a zero fail code next to a
    // populated post-mortem field).
    logic [4*N_FIELD-1:0] fields_q;

    logic [ PERIOD_W-1:0] period_q;
    logic [    IDX_W-1:0] idx_q;  // LINE_LEN = idle (line finished)

    wire                  sending = (idx_q != IDX_W'(LINE_LEN));

    function automatic logic [7:0] hex_digit(input logic [3:0] v);
        hex_digit = (v < 10) ? (8'h30 + 8'(v)) : (8'h41 + 8'(v) - 8'd10);
    endfunction

    // Byte at position idx of the line.
    function automatic logic [7:0] line_byte(input logic [IDX_W-1:0] idx);
        int field, sub;
        if (idx == IDX_W'(LINE_LEN - 2)) line_byte = 8'h0D;  // CR
        else if (idx == IDX_W'(LINE_LEN - 1)) line_byte = 8'h0A;  // LF
        else begin
            field = int'(idx) / 3;
            sub   = int'(idx) % 3;
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
            idx_q    <= IDX_W'(LINE_LEN);
            fields_q <= '0;
        end else begin
            period_q <= period_q + 1'b1;
            if (sending) begin
                if (tx_ready_i) idx_q <= idx_q + 1'b1;
            end else if (&period_q) begin
                idx_q    <= '0;
                fields_q <= fields_i;
            end
        end
    end

endmodule

`resetall
