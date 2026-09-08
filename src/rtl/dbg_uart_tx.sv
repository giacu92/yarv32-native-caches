`resetall
`timescale 1ns / 1ps
`default_nettype none

/**
 * Minimal 8N1 UART transmitter for board bring-up.
 *
 * Transmit only: the board never has to be told anything, it has to be
 * able to say what it is doing. One byte per `valid_i` handshake
 * (`valid_i && ready_o`), LSB first, one start bit and one stop bit, no
 * parity, no flow control.
 *
 * The divisor is computed from CLK_HZ / BAUD and rounded to nearest, which
 * is what keeps the accumulated error inside a character well under half a
 * bit at the rates this is used at (50 MHz / 115200 = 434.03 -> 434, an
 * error of 0.007%).
 *
 * Naming: ports use *_i/_o; internals no prefix; flops _q.
 */

module dbg_uart_tx #(
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD   = 115_200
) (
    input wire clk_i,
    input wire rstn_i,

    input  wire       valid_i,
    output wire       ready_o,
    input  wire [7:0] data_i,

    output wire txd_o
);

    localparam int DIVISOR = (CLK_HZ + BAUD / 2) / BAUD;
    localparam int DIV_W = $clog2(DIVISOR);

    // 10 bits on the wire: start, 8 data, stop.
    localparam int N_BITS = 10;

    logic [DIV_W-1:0] div_q;
    logic [      3:0] bit_q;  // 0 = idle, else bits remaining
    logic [ N_BITS:0] shift_q;  // shifted right, LSB first; MSBs are stop bits

    wire              busy = (bit_q != 4'd0);

    assign ready_o = !busy;
    assign txd_o   = busy ? shift_q[0] : 1'b1;  // line idles high

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            div_q   <= '0;
            bit_q   <= '0;
            shift_q <= '1;
        end else if (!busy) begin
            if (valid_i) begin
                // {stop, data, start}: shifted out LSB first.
                shift_q <= {1'b1, 1'b1, data_i, 1'b0};
                bit_q   <= N_BITS[3:0];
                div_q   <= DIV_W'(DIVISOR - 1);
            end
        end else if (div_q == 0) begin
            div_q   <= DIV_W'(DIVISOR - 1);
            shift_q <= {1'b1, shift_q[N_BITS:1]};
            bit_q   <= bit_q - 1'b1;
        end else begin
            div_q <= div_q - 1'b1;
        end
    end

endmodule

`resetall
