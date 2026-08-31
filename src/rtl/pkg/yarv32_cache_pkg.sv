`resetall
`timescale 1ns / 1ps
`default_nettype none

// Width-parametrizable native-protocol struct pair. SystemVerilog packages
// cannot parameterize typedefs, so these macros build the pair per
// (ADDR_W, DATA_W). Field order and semantics are fixed; only the widths
// vary:
//   REQ : valid, we, addr (byte address, ADDR_W bits), wdata (DATA_W bits),
//         wstrb (DATA_W/8 bits), rready
//   RSP : wready, rvalid, rdata (DATA_W bits), bvalid
// Expand into named typedefs at package or module scope
// (`YARV_MEM_TYPES), or directly in a port list (see native_ram, which
// re-expands with its own parameters). All struct-to-struct port
// connections are packed-vector assignments, so two expansions only
// connect cleanly when their widths match — an intentional width
// mismatch shows up as a WIDTH warning, not a type error.
`ifndef YARV_MEM_TYPES_SV
`define YARV_MEM_TYPES_SV
`define YARV_MEM_REQ_T(ADDR_W, DATA_W) \
    struct packed { \
        logic valid; \
        logic we; \
        logic [ADDR_W-1:0] addr; \
        logic [DATA_W-1:0] wdata; \
        logic [DATA_W/8-1:0] wstrb; \
        logic rready; \
    }
`define YARV_MEM_RSP_T(DATA_W) \
    struct packed { \
        logic wready; \
        logic rvalid; \
        logic [DATA_W-1:0] rdata; \
        logic bvalid; \
    }
`define YARV_MEM_TYPES(REQ_T, RSP_T, ADDR_W, DATA_W) \
    typedef `YARV_MEM_REQ_T(ADDR_W, DATA_W) REQ_T; \
    typedef `YARV_MEM_RSP_T(DATA_W) RSP_T;
`endif

package yarv32_cache_pkg;

    // CPU-side native protocol: 64-bit data, 64-bit byte address.
    localparam int unsigned MEM_WIDTH        = 64;
    localparam int unsigned STRB_WIDTH       = MEM_WIDTH / 8;

    // Cache-line variant: one whole cache line per RAM word (2^5 = 32 B
    // at CL_SIZE=5). Must stay consistent with cache_cntrl's
    // DATA_WIDTH = 2**(CL_SIZE+3).
    localparam int unsigned CACHE_WIDTH      = 256;
    localparam int unsigned CACHE_STRB_WIDTH = CACHE_WIDTH / 8;

    // Native protocol, CPU width: fetch/LSU side, bootrom.
    `YARV_MEM_TYPES(mem_req_t, mem_rsp_t, MEM_WIDTH, MEM_WIDTH)

    // Native protocol, cache-line width: cache data macros.
    `YARV_MEM_TYPES(cache_req_t, cache_rsp_t, MEM_WIDTH, CACHE_WIDTH)

    function automatic logic [6:0] cache_set_hash(
        input logic [22:0] addr  // indirizzo a 23 bit (spazio 8 MiB)
            );
        localparam int OFFSET_BITS = 5;  // 32-byte block
        localparam int SET_BITS = 7;  // 128 set

        logic [17:0] block_addr;  // addr senza i 5 bit di offset
        logic [ 6:0] h;

        block_addr = addr[22:OFFSET_BITS];  // 18 bit

        // Mixing aggressivo anche sui bit bassi
        h          = block_addr[6:0];  // [6:0]
        h ^= block_addr[9:3];  // >> 3
        h ^= block_addr[13:7];  // >> 7
        h ^= block_addr[17:11];  // >> 11
        h ^= {3'b0, block_addr[17:14]};
        h ^= block_addr[8:2];  // >> 2

        return h;  // già su 7 bit
    endfunction

endpackage

`resetall
