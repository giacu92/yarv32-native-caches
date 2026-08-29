`resetall
`timescale 1ns / 1ps
`default_nettype none

/**
 * Behavioral replacement for the Gowin SDRAM HS IP `SDRAM_Controller_HS_Top`.
 *
 * The real IP ships only as a post-PnR Gowin-primitive netlist (`.vo`) and an
 * encrypted post-synthesis netlist (`.vg`), neither of which Verilator can
 * elaborate. This stub exposes the identical port list (matching the
 * instantiation in `cache_cntrl.sv`) so the cache controller elaborates and
 * the miss/refill datapath can be exercised in simulation.
 *
 * It is a transactional model of the controller's cmd/data interface, not a
 * pin-accurate SDRAM chip model: there is no external DRAM, no pin timing,
 * no refresh/precharge. The external SDRAM pins (`O_sdram_*`, `IO_sdram_dq`)
 * are driven to inert defaults — they exist only to satisfy the port list.
 *
 * Protocol modeled (what `cache_cntrl`'s FSM drives):
 *   - O_sdrc_cmd_ack is asserted combinationally, coincident with
 *     I_sdrc_cmd_en, so the FSM's S_*_REQ state sees the handshake the same
 *     cycle and advances on the next edge.
 *   - Read  (I_sdrc_cmd == 3'b010): after the ack, stream I_sdrc_data_len
 *     consecutive 32-bit words from memory onto O_sdrc_data, one per cycle,
 *     starting the cycle after the ack — matching S_REFILL_WAIT, which
 *     samples O_sdrc_data every cycle for BURST_LEN words.
 *   - Write (I_sdrc_cmd == 3'b001): capture I_sdrc_data into memory for
 *     I_sdrc_data_len consecutive words, one per cycle, with word[0]
 *     captured at the ack cycle itself (the FSM drives sdrc_data from the
 *     ack cycle onward, so the stub must grab the first word at launch, not
 *     one cycle later).
 *   - O_sdrc_init_done rises a few cycles after reset deasserts; the FSM's
 *     S_WB_WAIT placeholder keys its completion off this.
 *
 * I_sdrc_addr is a 21-bit word index (byte address >> 2), so the memory is
 * 2^21 words x 32 bits = 8 MiB, matching the 23-bit SDRAM address space.
 *
 * Naming: ports *_i/_o per project convention; internals no prefix; flops _q.
 */

module SDRAM_Controller_HS_Top (
    input  wire        I_sdrc_rst_n,
    input  wire        I_sdrc_clk,
    input  wire        I_sdram_clk,
    input  wire        I_sdrc_cmd_en,
    input  wire [ 2:0] I_sdrc_cmd,
    input  wire        I_sdrc_precharge_ctrl,
    input  wire        I_sdram_power_down,
    input  wire        I_sdram_selfrefresh,
    input  wire [20:0] I_sdrc_addr,
    input  wire [ 3:0] I_sdrc_dqm,
    input  wire [31:0] I_sdrc_data,
    input  wire [ 7:0] I_sdrc_data_len,
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    output wire [ 3:0] O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [ 1:0] O_sdram_ba,
    output wire [31:0] O_sdrc_data,
    output reg         O_sdrc_init_done,
    output wire        O_sdrc_cmd_ack,
    inout  wire [31:0] IO_sdram_dq
);

    // -----------------------------------------------------------------
    // Command encoding (matches the placeholder values the FSM uses).
    // -----------------------------------------------------------------
    localparam logic [2:0] CMD_WRITE = 3'b001;
    localparam logic [2:0] CMD_READ = 3'b010;

    // -----------------------------------------------------------------
    // Backing store: 2^21 x 32-bit words = 8 MiB. Preloaded with a
    // recognizable pattern so refill reads return non-zero data.
    // -----------------------------------------------------------------
    localparam int MEM_WORDS = 1 << 21;
    logic [31:0] mem[0:MEM_WORDS-1];

    integer mi;
    initial begin
        for (mi = 0; mi < MEM_WORDS; mi = mi + 1) begin
            mem[mi] = 32'hCAFE0000 | {16'd0, mi[15:0]};
        end
    end

    // -----------------------------------------------------------------
    // Burst transaction machine.
    //   ST_IDLE: idle, awaiting a command. cmd_en latches addr/len and
    //            (for writes) captures word[0] at the launch edge.
    //   ST_RUN : streams the remaining words, one per cycle.
    // -----------------------------------------------------------------
    localparam logic ST_IDLE = 1'b0;
    localparam logic ST_RUN  = 1'b1;

    logic        st_q;
    logic [20:0] addr_q;  // starting word index
    logic [ 7:0] len_q;  // burst length (words)
    logic [ 7:0] cnt_q;  // words processed in ST_RUN
    logic        is_write_q;

    // Ack is combinational and coincident with cmd_en (only meaningful in
    // ST_IDLE; the FSM asserts cmd_en for exactly one cycle on reads and
    // for the whole burst on writes — here we ack every cycle cmd_en is up,
    // which is what the write burst expects).
    assign O_sdrc_cmd_ack = I_sdrc_cmd_en;

    // Read data: combinational from the current burst index so it is valid
    // the cycle the FSM's S_REFILL_WAIT first samples it.
    wire [20:0] rd_idx = (addr_q + {13'd0, cnt_q}) & 21'h1FFFFF;
    assign O_sdrc_data   = mem[rd_idx];

    // -----------------------------------------------------------------
    // External SDRAM pins: inert defaults (unused by this model).
    // -----------------------------------------------------------------
    assign O_sdram_clk   = I_sdram_clk;
    assign O_sdram_cke   = 1'b1;
    assign O_sdram_cs_n  = 1'b1;
    assign O_sdram_cas_n = 1'b1;
    assign O_sdram_ras_n = 1'b1;
    assign O_sdram_wen_n = 1'b1;
    assign O_sdram_dqm   = 4'h0;
    assign O_sdram_addr  = 11'h0;
    assign O_sdram_ba    = 2'h0;
    assign IO_sdram_dq   = 32'bz;

    // -----------------------------------------------------------------
    // Sequential burst + init handshake.
    // -----------------------------------------------------------------
    always_ff @(posedge I_sdrc_clk) begin
        if (!I_sdrc_rst_n) begin
            st_q             <= ST_IDLE;
            addr_q           <= '0;
            len_q            <= '0;
            cnt_q            <= '0;
            is_write_q       <= 1'b0;
            O_sdrc_init_done <= 1'b0;
        end else begin
            // Bring init_done up after reset so the FSM's S_WB_WAIT
            // placeholder can complete.
            O_sdrc_init_done <= 1'b1;

            case (st_q)
                ST_IDLE: begin
                    if (I_sdrc_cmd_en) begin
                        addr_q     <= I_sdrc_addr;
                        len_q      <= I_sdrc_data_len;
                        is_write_q <= (I_sdrc_cmd == CMD_WRITE);
                        // Writes capture word[0] at this (ack) edge below, so
                        // ST_RUN resumes at index 1. Reads present word[0]
                        // combinationally in ST_RUN, so they start at 0.
                        cnt_q      <= (I_sdrc_cmd == CMD_WRITE) ? 8'd1 : 8'd0;
                        st_q       <= ST_RUN;
                        // The FSM drives the write data from this very
                        // (ack) cycle; capture word[0] now to stay aligned.
                        if (I_sdrc_cmd == CMD_WRITE) begin
                            mem[I_sdrc_addr] <= I_sdrc_data;
                        end
                    end
                end

                ST_RUN: begin
                    if (is_write_q) begin
                        mem[(addr_q+{13'd0, cnt_q})&21'h1FFFFF] <= I_sdrc_data;
                    end
                    if (cnt_q == len_q - 1) begin
                        st_q  <= ST_IDLE;
                        cnt_q <= '0;
                    end else begin
                        cnt_q <= cnt_q + 8'd1;
                    end
                end

                default: st_q <= ST_IDLE;
            endcase
        end
    end

endmodule

`resetall
