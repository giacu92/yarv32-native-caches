`resetall
`timescale 1ns / 1ps
`default_nettype none

/**
 * SDRAM word-streaming engine.
 *
 * Presents the sdram_controller's one-word-at-a-time host interface as a
 * "move N consecutive words" command, so its callers can be written in
 * terms of whole cache lines (or single words) instead of per-word
 * handshakes. Everything the controller's protocol requires -- holding an
 * enable until busy rises because a due refresh may delay the accept,
 * ending a write on the busy fall, capturing a read on the rd_ready pulse
 * -- lives here and nowhere else.
 *
 * Command interface:
 *   - A command is accepted on the cycle cmd_valid_i && cmd_ready_o.
 *     cmd_ready_o is high only while the engine is idle.
 *   - cmd_we_i picks the direction, cmd_words_i (1 .. LINE_W/32) the
 *     length, cmd_addr_i the FIRST 32-bit word address; the engine walks
 *     cmd_addr_i, cmd_addr_i+1, ... itself.
 *   - done_o pulses for one cycle as the last word completes. It is
 *     asserted while cmd_ready_o is still low, so a caller that drives
 *     cmd_valid_i = cmd_ready_o cannot accidentally re-issue the command
 *     it just saw finish.
 *
 * Data:
 *   - Writes read their words out of cmd_wdata_i, low word first. It is
 *     NOT registered: the caller must hold it stable until done_o. (The
 *     cache's writeback source is the data macro's registered output,
 *     which is held for exactly that window, and registering a whole line
 *     here would cost LINE_W flops for nothing.)
 *   - Reads accumulate into rdata_o, low word first, and it HOLDS after
 *     done_o until the next read command overwrites those words. A read
 *     of fewer than LINE_W/32 words leaves the upper words at whatever
 *     the previous command left there, so a caller must only read back
 *     the words it asked for.
 *
 * Cost note: a command spends one cycle being accepted before the first
 * enable goes out, which the older inline version did not. That is one
 * cycle per COMMAND (four per cache miss at worst), not per word.
 *
 * Naming: ports use *_i/_o; internals no prefix; flops _q.
 */

module sdram_line_port #(
    // SDRAM address width in bytes (the controller's word address is
    // byte_addr[MEM_SIZE-1:2]).
    parameter int MEM_SIZE = 23,
    // Widest transfer, in bits. Sets the command length range and the
    // width of the data ports.
    parameter int LINE_W   = 256
) (
    input wire clk_i,
    input wire rstn_i,

    // Command
    input  wire                cmd_valid_i,
    output wire                cmd_ready_o,
    input  wire                cmd_we_i,     // 1 = write to SDRAM, 0 = read
    input  wire [         3:0] cmd_words_i,  // 1 .. LINE_W/32
    input  wire [MEM_SIZE-1:2] cmd_addr_i,   // first 32-bit word address
    input  wire [  LINE_W-1:0] cmd_wdata_i,  // write words, low word first

    output wire              done_o,  // one-cycle completion pulse
    output wire [LINE_W-1:0] rdata_o, // captured read words, held

    // sdram_controller host interface
    output wire                sdram_rd_en_o,
    output wire [MEM_SIZE-1:2] sdram_rd_addr_o,
    input  wire [        31:0] sdram_rd_data_i,
    input  wire                sdram_rd_ready_i,
    output wire                sdram_wr_en_o,
    output wire [MEM_SIZE-1:2] sdram_wr_addr_o,
    output wire [        31:0] sdram_wr_data_o,
    input  wire                sdram_busy_i
);

    localparam int WORD_ADDR_W = MEM_SIZE - 2;
    localparam int CNT_W = 4;  // cmd_words_i's width; covers LINE_W/32 <= 15

`ifdef VERILATOR
    initial begin
        assert (LINE_W / 32 <= (1 << CNT_W) - 1)
        else $fatal(1, "LINE_W (%0d) needs more than %0d command-length bits", LINE_W, CNT_W);
        assert (WORD_ADDR_W > CNT_W)
        else $fatal(1, "MEM_SIZE (%0d) too small for a %0d-bit word counter", MEM_SIZE, CNT_W);
    end
`endif

    typedef enum logic [2:0] {
        E_IDLE,
        E_WR_ISSUE,  // present the write word until the controller accepts
        E_WR_WAIT,   // accepted; the word is done when busy falls
        E_RD_ISSUE,  // present the read address until the controller accepts
        E_RD_WAIT    // accepted; the word arrives on the rd_ready pulse
    } eng_state_e;

    eng_state_e state_q, state_d;

    logic [CNT_W-1:0] cnt_q, cnt_d;  // word index within the command
    logic [CNT_W-1:0] words_q, words_d;  // command length
    logic [WORD_ADDR_W-1:0] addr_q, addr_d;  // first word address

    logic [LINE_W-1:0] rbuf_q, rbuf_d;

    // Last word of the command. words_q is at least 1 for any accepted
    // command, so this cannot underflow into a full-length transfer.
    wire last_word = (cnt_q == words_q - {{(CNT_W - 1) {1'b0}}, 1'b1});

    // The address of the word currently in flight.
    wire [WORD_ADDR_W-1:0] word_addr = addr_q + {{(WORD_ADDR_W - CNT_W) {1'b0}}, cnt_q};

    logic rd_en, wr_en, done;

    always_comb begin
        state_d = state_q;
        cnt_d   = cnt_q;
        words_d = words_q;
        addr_d  = addr_q;
        rbuf_d  = rbuf_q;

        rd_en   = 1'b0;
        wr_en   = 1'b0;
        done    = 1'b0;

        unique case (state_q)
            E_IDLE: begin
                cnt_d = '0;
                if (cmd_valid_i) begin
`ifdef VERILATOR
                    assert (cmd_words_i != '0)
                    else $fatal(1, "sdram_line_port: zero-length command");
`endif
                    words_d = cmd_words_i;
                    addr_d  = cmd_addr_i;
                    state_d = cmd_we_i ? E_WR_ISSUE : E_RD_ISSUE;
                end
            end

            // Hold the enable until busy rises (that is the accept; a due
            // refresh can delay it). Drop it on the accept: an enable still
            // up when the controller returns to IDLE reads as a new request.
            E_WR_ISSUE: begin
                wr_en = !sdram_busy_i;
                if (sdram_busy_i) state_d = E_WR_WAIT;
            end

            // The accepted write is complete when busy falls.
            E_WR_WAIT: begin
                if (!sdram_busy_i) begin
                    if (last_word) begin
                        done    = 1'b1;
                        state_d = E_IDLE;
                    end else begin
                        cnt_d   = cnt_q + 1'b1;
                        state_d = E_WR_ISSUE;
                    end
                end
            end

            E_RD_ISSUE: begin
                rd_en = !sdram_busy_i;
                if (sdram_busy_i) state_d = E_RD_WAIT;
            end

            // rd_ready is the controller's per-word data-valid strobe: one
            // cycle, carrying the word on rd_data.
            E_RD_WAIT: begin
                if (sdram_rd_ready_i) begin
                    rbuf_d[cnt_q*32+:32] = sdram_rd_data_i;
                    if (last_word) begin
                        done    = 1'b1;
                        state_d = E_IDLE;
                    end else begin
                        cnt_d   = cnt_q + 1'b1;
                        state_d = E_RD_ISSUE;
                    end
                end
            end

            default: state_d = E_IDLE;
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            state_q <= E_IDLE;
            cnt_q   <= '0;
            words_q <= '0;
            addr_q  <= '0;
            rbuf_q  <= '0;
        end else begin
            state_q <= state_d;
            cnt_q   <= cnt_d;
            words_q <= words_d;
            addr_q  <= addr_d;
            rbuf_q  <= rbuf_d;
        end
    end

    assign cmd_ready_o     = (state_q == E_IDLE);
    assign done_o          = done;
    assign rdata_o         = rbuf_q;

    // The controller samples address and data only on its enable, so these
    // are driven unconditionally off the word in flight.
    assign sdram_rd_en_o   = rd_en;
    assign sdram_wr_en_o   = wr_en;
    assign sdram_rd_addr_o = word_addr;
    assign sdram_wr_addr_o = word_addr;
    assign sdram_wr_data_o = cmd_wdata_i[cnt_q*32+:32];

endmodule

`resetall
