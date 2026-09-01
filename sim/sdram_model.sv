`resetall
`timescale 1ns / 1ps
`default_nettype none

/**
 * Behavioral model of the GW2AR-18 embedded SDRAM as seen by the
 * sdram_controller (src/ips/sdram-controller): 32-bit data, 11-bit row,
 * 8-bit column, 2-bit bank (8 MiB), CAS latency 3, burst length 1,
 * auto-precharge on READ/WRITE (A10 high).
 *
 * Unlike the old sdram_stub.sv (a transactional model of the Gowin HS IP's
 * host interface that merely mirrored the FSM's placeholder command
 * encodings), this model sits on the RAW SDRAM pins — the real controller
 * RTL runs in the Verilator sim, so a wrong command encoding, a missing
 * ACTIVATE, or a bad burst/auto-precharge sequence is caught here, not
 * hidden by a stub that agreed with the DUT by construction.
 *
 * Timing modeled:
 *   - READ sampled at edge t: the word is driven on dq during cycle t+3
 *     (registered at edge t+2), one cycle long — CL=3 as the controller's
 *     READ_READ capture stage expects.
 *   - WRITE: data is captured on the same edge as the WRITE command
 *     (single-word burst, data coincident with the command), byte-masked
 *     by dqm.
 *   - Row tracking: ACT opens a bank's row, A10-high READ/WRITE closes it
 *     (auto-precharge), PALL closes all rows. A READ/WRITE to a closed
 *     bank flags an error — the controller must ACTIVATE first.
 *   - REF needs no storage action (no retention in sim); MRS is latched
 *     and checked against the expected BL=1 / CL=3 mode word.
 *
 * The backing array is preloaded with a recognizable pattern so refills
 * return non-zero data: word value = 32'hCAFE0000 | word_index[15:0],
 * word_index = {bank, row, col} = byte_addr[22:2] (sim_top's sdram_word
 * expectation matches this).
 *
 * Naming: ports named after the SDRAM pin they model; internals no prefix;
 * flops _q.
 */

module sdram_model (
    input wire        clk,
    input wire        cke,
    input wire        cs_n,
    input wire        ras_n,
    input wire        cas_n,
    input wire        we_n,
    input wire [ 3:0] dqm,
    input wire [10:0] addr,
    input wire [ 1:0] ba,
    inout wire [31:0] dq
);

    // -----------------------------------------------------------------
    // Backing store: 4 banks x 2^11 rows x 2^8 cols x 32 bits = 2^21
    // words = 8 MiB, indexed by the linear word address {bank, row, col}.
    // -----------------------------------------------------------------
    localparam int MEM_WORDS = 1 << 21;

    logic [31:0] mem[0:MEM_WORDS-1];

    integer mi;
    initial begin
        for (mi = 0; mi < MEM_WORDS; mi = mi + 1) begin
            mem[mi] = {16'hCAFE, mi[15:0]};
        end
    end

    // -----------------------------------------------------------------
    // Command decode (sampled on posedge clk when cke; cs_n high = NOP).
    //   ACT : ras=0 cas=1 we=1   READ  : ras=1 cas=0 we=1
    //   PALL: ras=0 cas=1 we=0   WRITE : ras=1 cas=0 we=0
    //   REF : ras=0 cas=0 we=1   MRS   : ras=0 cas=0 we=0
    // -----------------------------------------------------------------
    wire           cmd_sampled = cke && !cs_n;
    wire           is_act = cmd_sampled && !ras_n && cas_n && we_n;
    wire           is_read = cmd_sampled && ras_n && !cas_n && we_n;
    wire           is_write = cmd_sampled && ras_n && !cas_n && !we_n;
    wire           is_pall = cmd_sampled && !ras_n && cas_n && !we_n;
    wire           is_ref = cmd_sampled && !ras_n && !cas_n && we_n;
    wire           is_mrs = cmd_sampled && !ras_n && !cas_n && !we_n;

    // -----------------------------------------------------------------
    // Row-bank state + read pipeline.
    // -----------------------------------------------------------------
    logic          row_open_q                                           [4];
    logic   [10:0] row_q                                                [4];
    logic   [ 9:0] mode_q;
    logic   [ 3:0] rd_pipe_q;  // read data pipeline position (CL=3)
    logic          dq_oe_q;  // driving dq this cycle (read data window)
    logic   [31:0] dq_q;  // driven read data
    logic   [20:0] rd_idx_q;  // {bank, row, col} of the in-flight read
    integer        protocol_errors = 0;

    // The word index of a bank access: the open row (latched at ACT) plus
    // the column presented at READ/WRITE (addr[7:0]; addr[10] is A10).
    wire    [20:0] rw_idx = {ba, row_q[ba], addr[7:0]};

    assign dq = dq_oe_q ? dq_q : 32'bz;

    initial begin
        for (integer b = 0; b < 4; b++) begin
            row_open_q[b] = 1'b0;
            row_q[b]      = '0;
        end
        mode_q    = '0;
        rd_pipe_q = '0;
        dq_oe_q   = 1'b0;
        dq_q      = '0;
        rd_idx_q  = '0;
    end

    always_ff @(posedge clk) begin
        // Read data window: one cycle, driven so the controller's 3rd-edge
        // capture sees it (see header).
        dq_oe_q <= 1'b0;
        if (rd_pipe_q != 0) begin
            if (rd_pipe_q == 4'd1) begin
                dq_q      <= mem[rd_idx_q];
                dq_oe_q   <= 1'b1;
                rd_pipe_q <= '0;
            end else begin
                rd_pipe_q <= rd_pipe_q - 4'd1;
            end
        end

        if (is_act) begin
            row_open_q[ba] <= 1'b1;
            row_q[ba]      <= addr;
        end else if (is_read) begin
            if (!row_open_q[ba]) begin
                protocol_errors <= protocol_errors + 1;
                $display("SDRAM MODEL ERROR: READ to closed bank %0d", ba);
            end
            rd_pipe_q <= 4'd2;  // drive at edge t+2, sampled at edge t+3
            rd_idx_q  <= rw_idx;
            if (addr[10]) row_open_q[ba] <= 1'b0;  // auto-precharge
        end else if (is_write) begin
            if (!row_open_q[ba]) begin
                protocol_errors <= protocol_errors + 1;
                $display("SDRAM MODEL ERROR: WRITE to closed bank %0d", ba);
            end
            for (int byi = 0; byi < 4; byi++) begin
                if (!dqm[byi]) mem[rw_idx][byi*8+:8] <= dq[byi*8+:8];
            end
            if (addr[10]) row_open_q[ba] <= 1'b0;  // auto-precharge
        end else if (is_pall) begin
            if (addr[10]) begin
                for (int b = 0; b < 4; b++) row_open_q[b] <= 1'b0;
            end
        end else if (is_mrs) begin
            mode_q <= addr[9:0];
            if (addr[9:0] != 10'b1000110000) begin
                protocol_errors <= protocol_errors + 1;
                $display("SDRAM MODEL ERROR: unexpected mode word %b", addr[9:0]);
            end
        end else if (is_ref) begin
            // No retention to maintain in sim.
        end
    end

    final begin
        if (protocol_errors != 0) begin
            $display("SDRAM MODEL: %0d protocol error(s)", protocol_errors);
        end
    end

endmodule

`resetall
