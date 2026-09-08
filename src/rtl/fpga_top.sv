`resetall
`timescale 1ns / 1ps
`default_nettype none

import yarv32_cache_pkg::*;

/**
 * Board top for the Sipeed Tang Nano 20K (Gowin GW2AR-LV18QN88C8/I7).
 *
 * Wires the cache subsystem to the board: clock generation, reset
 * synchronization, the bring-up self test (cache_bist), status LEDs, and
 * the pins of the GW2AR-18's embedded 8 MiB SDRAM.
 *
 *   clk_i (25 MHz) --> rPLL --> clk_core (50 MHz)  --> cache_cntrl, cache_bist
 *                           \-> sdram_clk (50 MHz, phase shifted) --> O_sdram_clk
 *
 * SDRAM port names: the embedded SDRAM is a SIP die, NOT board wiring —
 * it gets no `.cst` entries. The Gowin toolchain connects it by MATCHING
 * THE TOP-LEVEL PORT NAMES, which is why the ports below are
 * `O_sdram_*` / `IO_sdram_dq` and not the project's usual `*_o` / `*_io`
 * convention. Renaming them silently leaves the SDRAM unconnected.
 *
 * Naming: the SDRAM ports are the documented exception above; every other
 * port follows *_i/_o, internals no prefix, flops _q.
 */

module fpga_top #(
`ifdef GATESIM
    // A synthesized netlist has no parameters, so the gate-level testbench
    // cannot override these — they are baked in here instead, at the same
    // fast values the RTL testbench passes.
    parameter int UART_BAUD = 12_500_000,
    parameter int UART_PERIOD_W = 9,
`else
    // Debug UART baud. 115200 on the board; the testbench overrides it to
    // something far faster so a whole line fits in a short simulation.
    parameter int UART_BAUD = 115_200,
    // Status line period, 2**UART_PERIOD_W clocks (~0.34 s at 50 MHz).
    parameter int UART_PERIOD_W = 24,
`endif
    // $readmemh image for the bootrom macro (2 KiB, 256 x 64 bit), mapped
    // at BOOTROM_BASE. Empty until there is boot code to put in it: the
    // macro is wired to both CPU ports either way, but an uninitialised
    // read-only array is a constant, and GowinSynthesis is entitled to
    // build it as one (see native_ram's ram_style comment).
    parameter string BOOTROM_FILE = ""
) (
    // 25 MHz reference clock from the MS5351M clock generator (crystal-fed,
    // CLK0 on PIN10, plain LVCMOS33 — no differential pair).
    input wire clk_i,
    // Board reset button S1 on PIN88. ACTIVE HIGH on this board: the pin is
    // pulled low when the button is released, so the design runs untouched
    // and resets only while S1 is held.
    input wire rst_i,

    // Debug UART, transmit only, into the onboard BL616 USB-UART bridge.
    // 115200 8N1: one status line per period, see dbg_reporter.
    output wire uart_txd_o,

    // Status LEDs. The board LEDs are ACTIVE LOW (anode at 3.3 V), so the
    // pins are driven with the inverted status bits below.
    // The bank has two views, because a failed board raises different
    // questions than a running one:
    //   running / passed: [0] fail (dark), [1] pass, [2] busy,
    //                     [3] heartbeat, [5:4] dark
    //   failed:           [1:0] why it failed (01 data mismatch, 10 D-port
    //                     watchdog, 11 I-port watchdog — never 00, so a
    //                     lit low LED IS the failure indication), and
    //                     [5:2] the cache's miss-FSM state at that moment
    output wire [5:0] led_o,

    // GW2AR-18 embedded SDRAM (8 MiB). Fixed names — see header.
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    output wire [ 3:0] O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [ 1:0] O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);

    // Core clock frequency in MHz. MUST match the rPLL settings below and
    // the SDC's generated clock: cache_cntrl divides it down to space the
    // SDRAM refresh bursts, so a stale value here under-refreshes the chip.
    localparam int CLK_FREQ_MHZ = 50;

    // Build identity, printed as the debug UART's V field. BUMP IT with
    // every bitstream that changes behaviour: without it two builds print
    // identical status lines and there is no way to tell from the board
    // whether the fix under test is actually the one running.
    //   1 = first bring-up build
    //   2 = fail code + LED post-mortem
    //   3 = UART reporter, counters, hang hold
    //   4 = packed state arrays (no inferred memories) + 200 us SDRAM
    //       power-up hold
    //   5 = accept counter + live lookup/answer taps (A, K, R)
    //   6 = unconditional power-on reset + free-running tick probe (T)
    //   7 = debug counters pinned with syn_preserve / syn_keep
    //   8 = cache_cntrl's own heartbeat wired straight to led_o[5]
    //   9 = tag invalidation sweep at reset (the gate-level root cause)
    //  10 = defined power-up state for the reset chain (Initialize_Primitives)
    //  11 = single external reset, registered, no POR counter / lock gate
    //  12 = yarv32-uc CPU interface: 64-bit read-only I port (ifetch_*),
    //       32-bit byte-strobed D port (mem_*)
    //  13 = SDRAM per-word handshakes moved into sdram_line_port (the
    //       miss FSM's state encoding, and so dbg_state_o, changed)
    //  14 = tag macros in LUT SSRAM (36 -> 32 BSRAM blocks); the UART
    //       reports a verdict only ("PASS", or "FAIL" + the fields)
    localparam logic [3:0] BUILD_ID = 4'd14;

    // -------------------------------------------------------------------
    // Clock generation
    //
    // clk_core = FCLKIN * FBDIV / IDIV = 25 * 10 / 5 = 50 MHz (20 ns).
    //   IDIV_SEL=4 -> IDIV=5   : PFD  =   5 MHz (allowed 3-400)
    //   FBDIV_SEL=9 -> FBDIV=10: CLKOUT = 50 MHz (allowed 3.125-600)
    //   ODIV_SEL=16            : VCO  = 800 MHz (allowed 500-1250; this
    //                            primitive caps ODIV_SEL at 16 and
    //                            silently substitutes 8 above it)
    //
    // The SDRAM clock phase, as the rPLL's PSDA_SEL code: 1/16-period
    // steps, "1000" = 180 degrees. Named here because bring-up sweeps it
    // (see the note below) and one edit should be enough.
    localparam string SDRAM_PSDA_SEL = "1000";

    // sdram_clk is CLKOUTP, the same 50 MHz shifted by PSDA_SEL in 1/16
    // period steps (DYN_DA_EN="false" => the shift is the static
    // PSDA_SEL value). "1000" = 8/16 = 180 degrees: commands and write
    // data launched by the controller on a clk_core rising edge are
    // sampled by the SDRAM half a period later, i.e. at their most
    // settled point, and read data returns half a period before the
    // capturing edge. 180 degrees is the starting point for bring-up, not
    // a measured optimum — if reads are flaky on the board, sweep
    // PSDA_SEL (e.g. "1100" = 270 deg / "0100" = 90 deg) and keep what
    // gives the widest working window.
    // -------------------------------------------------------------------

    wire clk_core;
    wire sdram_clk;

`ifdef VERILATOR
    // The rPLL is a Gowin hard macro with no Verilator model. The lint /
    // elaboration build (`make lint-fpga`) runs the wrapper on the raw
    // reference clock instead; this branch is never synthesized.
    assign clk_core  = clk_i;
    assign sdram_clk = clk_i;
`else
    rPLL #(  // GW2AR-LV18QN88C8/I7 (Tang Nano 20K)
        .FCLKIN   ("25"),
        .IDIV_SEL (4),
        .FBDIV_SEL(9),
        .ODIV_SEL (16),
        .PSDA_SEL (SDRAM_PSDA_SEL),  // CLKOUTP phase, see above
        .DYN_DA_EN("false")          // static phase shift: PSDA_SEL is the value
    ) u_pll (
        .CLKOUTP (sdram_clk),
        .CLKOUTD (),
        .CLKOUTD3(),
        .RESET   (1'b0),
        .RESET_P (1'b0),
        .CLKFB   (1'b0),
        .FBDSEL  (6'b0),
        .IDSEL   (6'b0),
        .ODSEL   (6'b0),
        .PSDA    (4'b0),
        .DUTYDA  (4'b0),
        .FDLY    (4'b0),
        .CLKIN   (clk_i),
        .CLKOUT  (clk_core),
        .LOCK    ()
    );
`endif

    // -------------------------------------------------------------------
    // Reset
    //
    // One reset for the whole design: the external button, registered and
    // fanned out. rst_i is asynchronous (a button, ACTIVE HIGH on this
    // board) so it goes through a two-flop synchroniser onto clk_core, and
    // rstn_core is the single active-low reset every submodule below takes.
    // Nothing else gates it: no power-on counter, no PLL lock term.
    // -------------------------------------------------------------------

    logic [1:0] rst_sync_q = 2'b11;

    always_ff @(posedge clk_core) begin
        rst_sync_q <= {rst_sync_q[0], rst_i};
    end

    wire                rstn_core = ~rst_sync_q[1];

    // -------------------------------------------------------------------
    // Cache subsystem + bring-up self test
    // -------------------------------------------------------------------

    ifetch_req_t        icache_req;
    ifetch_rsp_t        icache_rsp;
    mem_req_t           dcache_req;
    mem_rsp_t           dcache_rsp;

    wire                bist_busy;
    wire                bist_pass;
    wire                bist_fail;
    wire         [ 1:0] bist_fail_code;
    wire         [ 3:0] bist_fail_state;
    wire         [ 3:0] bist_fail_stage;
    wire         [ 3:0] bist_fail_dport;
    wire         [ 3:0] cache_dbg_state;
    wire         [ 3:0] cache_dbg_dport;
    wire         [15:0] cache_dbg_cnt;
    wire         [ 3:0] cache_dbg_acc;
    wire         [ 3:0] cache_dbg_go;
    wire         [ 3:0] cache_dbg_rsp;
    wire         [ 3:0] cache_dbg_tick;
    wire                cache_dbg_hb;
    wire         [ 3:0] bist_dbg_stage;
    wire         [ 3:0] bist_dbg_idx;
    wire         [ 3:0] bist_dbg_hs;

    cache_bist u_bist (
        .clk_i       (clk_core),
        .rstn_i      (rstn_core),
        .icache_req_o(icache_req),
        .icache_rsp_i(icache_rsp),
        .dcache_req_o(dcache_req),
        .dcache_rsp_i(dcache_rsp),
        .busy_o      (bist_busy),
        .pass_o      (bist_pass),
        .fail_o      (bist_fail),
        .fail_code_o (bist_fail_code),
        .fail_state_o(bist_fail_state),
        .fail_stage_o(bist_fail_stage),
        .fail_dport_o(bist_fail_dport),
        .dbg_state_i (cache_dbg_state),
        .dbg_dport_i (cache_dbg_dport),
        .dbg_stage_o (bist_dbg_stage),
        .dbg_idx_o   (bist_dbg_idx),
        .dbg_hs_o    (bist_dbg_hs)
    );

    cache_cntrl #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ),
        .BOOTROM_FILE(BOOTROM_FILE)
    ) u_cache (
        .clk_i        (clk_core),
        .rstn_i       (rstn_core),
        .sdram_clk_i  (sdram_clk),
        .icache_req_i (icache_req),
        .icache_rsp_o (icache_rsp),
        .dcache_req_i (dcache_req),
        .dcache_rsp_o (dcache_rsp),
        .sdram_clk_o  (O_sdram_clk),
        .sdram_cke_o  (O_sdram_cke),
        .sdram_cs_n_o (O_sdram_cs_n),
        .sdram_cas_n_o(O_sdram_cas_n),
        .sdram_ras_n_o(O_sdram_ras_n),
        .sdram_wen_n_o(O_sdram_wen_n),
        .sdram_dqm_o  (O_sdram_dqm),
        .sdram_addr_o (O_sdram_addr),
        .sdram_ba_o   (O_sdram_ba),
        .sdram_dq_io  (IO_sdram_dq),
        .dbg_state_o  (cache_dbg_state),
        .dbg_dport_o  (cache_dbg_dport),
        .dbg_cnt_o    (cache_dbg_cnt),
        .dbg_acc_o    (cache_dbg_acc),
        .dbg_go_o     (cache_dbg_go),
        .dbg_rsp_o    (cache_dbg_rsp),
        .dbg_tick_o   (cache_dbg_tick),
        .dbg_hb_o     (cache_dbg_hb)
    );

    // -------------------------------------------------------------------
    // Debug UART: "F0 G0 C0 D0 B1 I3 S4" once per period.
    //   F = BIST fail code            G = BIST stage AT the failure
    //   C = cache miss-FSM state at the failure
    //   D = cache D-port bits at the failure (cache_cntrl.dbg_dport_o)
    //   B = BIST stage (live)         I = BIST vector index (live)
    //   S = {0, busy, pass, fail}
    //   L P M U = D-cache event counts, saturating at F: Lookups launched,
    //             tag Pulses seen, Misses picked up, Unstalls done. Read
    //             them left to right: the first one that stopped counting
    //             is the step that never happened.
    //   E = the D-port bits LIVE (same encoding as D)
    //   W = the handshake the BIST sees: {wready, rvalid, req.wvalid, we}
    //   V = build id (BUILD_ID above): says which bitstream is running
    //   A = D-port accepts (control counter: the skid slot cannot be
    //       occupied with A at 0, so a zero there indicts the counters)
    //   K = live lookup issue: {go, fsm gate, tag req valid, tag wready}
    //   R = live answers:      {tag rvalid, data rvalid, slot_rsp[0..1]}
    //   T = free-running tick inside cache_cntrl. It MUST differ between
    //       report lines: if it does not, that module's flops are not
    //       advancing and every zero counter above says nothing.
    // With the BIST's hang hold, a stalled board keeps driving its request,
    // so E and W describe the stall itself, not the recovery from it.
    // The live pair says where a running board is; the latched trio says
    // where a failed one stopped, which the live pair cannot — by the time
    // anyone reads it, the stage is S_DONE and the index has stopped
    // meaning anything.
    // -------------------------------------------------------------------

    wire [3:0] dbg_status = {1'b0, bist_busy, bist_pass, bist_fail};

    wire       tx_valid;
    wire       tx_ready;
    wire [7:0] tx_data;

    dbg_reporter #(
        .N_FIELD (18),
        .LABELS  ("FGCDBISLPMUEWVAKRT"),
        .PERIOD_W(UART_PERIOD_W)
    ) u_reporter (
        .clk_i(clk_core),
        .rstn_i(rstn_core),
        .fields_i({
            cache_dbg_tick,
            cache_dbg_rsp,
            cache_dbg_go,
            cache_dbg_acc,
            BUILD_ID,
            bist_dbg_hs,
            cache_dbg_dport,
            cache_dbg_cnt,  // U M P L, most significant field first
            dbg_status,
            bist_dbg_idx,
            bist_dbg_stage,
            bist_fail_dport,
            bist_fail_state,
            bist_fail_stage,
            {2'b00, bist_fail_code}
        }),
        .pass_i(bist_pass),
        .fail_i(bist_fail),
        .tx_valid_o(tx_valid),
        .tx_ready_i(tx_ready),
        .tx_data_o(tx_data)
    );

    dbg_uart_tx #(
        .CLK_HZ(CLK_FREQ_MHZ * 1_000_000),
        .BAUD  (UART_BAUD)
    ) u_uart_tx (
        .clk_i  (clk_core),
        .rstn_i (rstn_core),
        .valid_i(tx_valid),
        .ready_o(tx_ready),
        .data_i (tx_data),
        .txd_o  (uart_txd_o)
    );

    // -------------------------------------------------------------------
    // Status LEDs (active low on this board)
    // -------------------------------------------------------------------

    logic [24:0] hb_q;

    always_ff @(posedge clk_core) begin
        if (!rstn_core) hb_q <= '0;
        else hb_q <= hb_q + 1'b1;
    end

    // ~1.5 Hz blink at 50 MHz (2**24 / 50e6 s per half period).
    //
    // On a failure the bank switches to the post-mortem view. led_o[0]
    // stays a dedicated failure light, which leaves five LEDs for the six
    // bits of (fail code, miss-FSM state) — so the two fields alternate in
    // frames, marked by led_o[1], at the rate the board was already
    // blinking at.
    wire       fail_frame = hb_q[24];
    wire [3:0] fail_payload = fail_frame ? bist_fail_state : {2'b00, bist_fail_code};

    // led_o[5] is the cache's OWN heartbeat, in both views and whatever the
    // verdict: a flop inside cache_cntrl driving a pin through a wire. If
    // it blinks, that module is clocked; if it stays put while led_o[3]
    // blinks, it is not — a reading that needs no counter, no report path
    // and no UART to be correct.
    assign led_o = ~{cache_dbg_hb, bist_fail ? {fail_payload[2:0], fail_frame, 1'b1} :
                     {1'b0, hb_q[24], bist_busy, bist_pass, 1'b0}};

endmodule

`resetall
