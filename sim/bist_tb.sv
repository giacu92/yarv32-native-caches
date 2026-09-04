`resetall
`timescale 1ns / 1ps
`default_nettype none

/**
 * Testbench for the FPGA board top (fpga_top) + its bring-up self test.
 *
 * Runs exactly what the Tang Nano 20K build runs: fpga_top (rPLL bypassed
 * under Verilator, so the core clock is the reference clock here) driving
 * cache_bist against the real sdram_controller and the behavioral
 * GW2AR-18 SDRAM model. It is the pre-silicon answer to "will the board
 * light PASS or FAIL", and it keeps the wrapper from rotting: a broken
 * port connection or a self test that never terminates fails here instead
 * of on the bench.
 *
 * The board LEDs are active low, so a lit LED is a 0 on the pin, and the
 * bank has two views (see fpga_top): [0] dark while running or on a pass
 * ([1] pass, [2] busy, [3] heartbeat), lit on a failure, where [5:2] then
 * carries the fail code while [1] is dark and the miss-FSM state while it
 * is lit. The frame marker toggles at the heartbeat rate, far slower than
 * this testbench runs, so only the code frame is ever visible here; the
 * state is read out hierarchically for the failure message instead.
 */

module bist_tb;

    // 50 MHz — the real Tang Nano 20K core clock (fpga_top's rPLL output,
    // bypassed to this clock under Verilator).
    localparam time CLK_HALF = 10ns;

    // The self test is 8 store misses + 8 load misses, each a full SDRAM
    // round trip (writeback + refill, ~200 cycles), and it only starts
    // once cache_cntrl releases the SDRAM controller from its power-up
    // hold.
    // Covers the 200 us SDRAM power-up wait plus the test and, on a
    // failure, the post-mortem report line.
    localparam time TIMEOUT = 900us;

    logic clk;
    logic rst;

    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    wire [ 5:0] led;
    wire        uart_txd;

    wire        sdram_clk;
    wire        sdram_cke;
    wire        sdram_cs_n;
    wire        sdram_cas_n;
    wire        sdram_ras_n;
    wire        sdram_wen_n;
    wire [ 3:0] sdram_dqm;
    wire [10:0] sdram_addr;
    wire [ 1:0] sdram_ba;
    wire [31:0] sdram_dq;

    // The debug UART is sped up so whole status lines fit in this
    // simulation: 4 clocks per bit instead of 434, and a line every 512
    // clocks instead of every 2**24 — an 11-field line is ~1400 clocks on
    // the wire, so a slower period would not finish one inside this run.
    // The board build keeps the defaults.
    fpga_top #(
        .UART_BAUD    (12_500_000),
        .UART_PERIOD_W(9)
    ) u_dut (
        .clk_i        (clk),
        .rst_i        (rst),
        .uart_txd_o   (uart_txd),
        .led_o        (led),
        .O_sdram_clk  (sdram_clk),
        .O_sdram_cke  (sdram_cke),
        .O_sdram_cs_n (sdram_cs_n),
        .O_sdram_cas_n(sdram_cas_n),
        .O_sdram_ras_n(sdram_ras_n),
        .O_sdram_wen_n(sdram_wen_n),
        .O_sdram_dqm  (sdram_dqm),
        .O_sdram_addr (sdram_addr),
        .O_sdram_ba   (sdram_ba),
        .IO_sdram_dq  (sdram_dq)
    );

    sdram_model u_sdram (
        .clk  (sdram_clk),
        .cke  (sdram_cke),
        .cs_n (sdram_cs_n),
        .ras_n(sdram_ras_n),
        .cas_n(sdram_cas_n),
        .we_n (sdram_wen_n),
        .dqm  (sdram_dqm),
        .addr (sdram_addr),
        .ba   (sdram_ba),
        .dq   (sdram_dq)
    );

    wire [5:0] led_n = ~led;
    wire bist_fail = led_n[0];
    wire bist_pass = !bist_fail && led_n[1];
    wire bist_busy = !bist_fail && led_n[2];
    // Code frame only (see the header); the state comes from the DUT.
    wire [1:0] fail_code = led_n[3:2];
    wire [3:0] fail_state = u_dut.u_bist.fail_state_q;

    initial begin
        $dumpfile("bist_tb.vcd");
        $dumpvars(0, bist_tb);

        // Board reset button is active high: hold, then release.
        rst = 1'b1;
        repeat (10) @(posedge clk);
        rst = 1'b0;

        wait (bist_pass || bist_fail);

        // The SDRAM model's protocol checks (power-up window, MRS before
        // access, tRP / tRFC / tRCD) are part of the verdict: passing the
        // data checks while violating the device's rules is what let a
        // controller with a 300 ns power-up wait look healthy here.
        if (u_sdram.protocol_errors != 0)
            $display("[bist_tb] FAIL: %0d SDRAM protocol violation(s)", u_sdram.protocol_errors);

        if (bist_pass)
            $display("[bist_tb] PASS: self test passed at %0t (busy=%0b)", $time, bist_busy);
        else
            $display(
                "[bist_tb] FAIL: self test reported a failure at %0t (fail_code=%02b state=%0d)",
                $time,
                fail_code,
                fail_state
            );

        // On a failure, give the reporter time to emit a full status line
        // first: the BIST holds the stalled request (hang hold), so that
        // line is the post-mortem, and killing the run before it prints
        // would throw away the only evidence.
        // Long enough for a line that STARTED after the failure: the
        // reporter samples its fields at line start, so a shorter wait
        // catches the line already in flight, which predates the failure.
        repeat (bist_fail ? 5000 : 10) @(posedge clk);
        if (bist_fail || u_sdram.protocol_errors != 0) $fatal(1, "[bist_tb] BIST FAILED");
        $finish;
    end

    // Debug-UART monitor: decode the TX line and print each status line as
    // it completes. It is the same text the board sends to its USB bridge,
    // so a bring-up reading and a simulation reading are directly
    // comparable — and the framing is proven here before anything is
    // flashed.
    localparam time UART_BIT = 80ns;  // 12.5 Mbaud against the 50 MHz clock

    initial begin
        static byte unsigned ch = 8'h00;
        static string line = "";
        forever begin
            @(negedge uart_txd);  // start bit
            #(UART_BIT + UART_BIT / 2);  // settle in the middle of bit 0
            for (int b = 0; b < 8; b++) begin
                ch[b] = uart_txd;
                #UART_BIT;
            end
            if (ch == 8'h0A) begin
                $display("[bist_tb] uart: %s", line);
                line = "";
            end else if (ch != 8'h0D) begin
                line = {line, string'(ch)};
            end
        end
    end

    // Watchdog: a self test that never finishes is a failure, not a hang.
    initial begin
        #TIMEOUT;
        $fatal(1, "[bist_tb] TIMEOUT after %0t with led=%b (busy=%0b)", TIMEOUT, led, bist_busy);
        // led bits, MSB first: fail code [5:4], heartbeat, busy, pass, fail
    end

endmodule

`resetall
