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
//
// The CPU-facing types (ifetch_req_t/ifetch_rsp_t, and the 32-bit
// mem_req_t/mem_rsp_t) are NOT built from these macros: the two CPU ports
// have different field sets (the I port is read-only and its response has
// no bvalid), so they are hand-declared bit-identical to the yarv32-uc
// core's rv32_pkg typedefs. Field ORDER is load-bearing for exactly the
// same reason — a struct-to-struct connection is a packed-vector copy.
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

    // Byte-address width of every native-protocol port (CPU-facing,
    // bootrom, cache data/tag macros). The yarv32-uc core emits 32-bit
    // byte addresses; the region decode below looks at bits [23] and [12]
    // only, so bits above 23 are ignored by construction.
    localparam int unsigned NATIVE_ADDR_W = 32;

    // CPU port data widths: the fetch side reads 64 bits at a time (two
    // 32-bit instructions), the LSU moves one 32-bit word.
    localparam int unsigned IFETCH_DATA_W = 64;
    localparam int unsigned LSU_DATA_W = 32;
    localparam int unsigned LSU_STRB_W = LSU_DATA_W / 8;

    // Cache-line variant: one whole cache line per RAM word (2^5 = 32 B
    // at CL_SIZE=5). Must stay consistent with cache_cntrl's
    // DATA_WIDTH = 2**(CL_SIZE+3).
    localparam int unsigned CACHE_WIDTH = 256;
    localparam int unsigned CACHE_STRB_WIDTH = CACHE_WIDTH / 8;

    // Legacy macro-pair width constants: the line-width pair below and
    // the internal line/tag macro expansions in cache_cntrl still use
    // them (64-bit data words there, not the CPU widths).
    localparam int unsigned MEM_WIDTH = 64;
    localparam int unsigned STRB_WIDTH = MEM_WIDTH / 8;

    // Native protocol, cache-line width: cache data macros.
    `YARV_MEM_TYPES(cache_req_t, cache_rsp_t, NATIVE_ADDR_W, CACHE_WIDTH)

    // Bootrom protocol: same macro shape, but 32-bit byte address. The
    // bootrom macro stays 64-bit data (the I port fetches 8 bytes), so
    // this is the pair its native_ram instance uses.
    `YARV_MEM_TYPES(boot_req_t, boot_rsp_t, NATIVE_ADDR_W, IFETCH_DATA_W)

    // ------------------------------------------------------------------
    // CPU-facing port types, bit-identical to the yarv32-uc core's
    // rv32_pkg typedefs (field names AND order). Struct-to-struct
    // connections are packed-vector copies, so any drift from rv32_pkg
    // silently misconnects — cache_cntrl pins the widths with
    // elaboration-time $bits asserts.
    // ------------------------------------------------------------------

    // Instruction fetch port (I side): read-only, 64-bit, up to 2 reads
    // outstanding, responses in request order.
    typedef struct packed {
        logic valid;  // request valid (launch a read)
        logic [NATIVE_ADDR_W-1:0] addr;  // byte address, 8-byte aligned in steady state
        logic rready;  // master ready to accept read data
    } ifetch_req_t;

    typedef struct packed {
        logic ready;  // slave accepts the request (skid not full)
        logic rvalid;  // read data valid this cycle
        logic [IFETCH_DATA_W-1:0] rdata;  // two 32-bit words, low word first
    } ifetch_rsp_t;

    // Data (LSU) port (D side): 32-bit read/write, byte-strobed,
    // single-outstanding. Stores are posted (retire at accept; the core
    // ignores bvalid, which stays low). Addresses are word-aligned by the
    // core; bit-28 addresses are the core's MMIO and go to its AXI4-Lite
    // master — they never reach this port.
    typedef struct packed {
        logic wvalid;  // request valid
        logic we;  // 1 = write, 0 = read
        logic [NATIVE_ADDR_W-1:0] addr;  // byte address, word-aligned
        logic [LSU_DATA_W-1:0] wdata;  // write data (ignored if we=0)
        logic [LSU_STRB_W-1:0] wstrb;  // byte strobes; all-1 on a word store
        logic rready;  // master ready for read data
    } mem_req_t;

    typedef struct packed {
        logic wready;  // slave accepts the request
        logic rvalid;  // read data valid this cycle
        logic [LSU_DATA_W-1:0] rdata;  // read data
        logic bvalid;  // write ack — stores are posted, held low
    } mem_rsp_t;

    // ------------------------------------------------------------------
    // System address map (24 bit). The SDRAM needs 23 bits for its 8 MiB,
    // so bit 23 is free and separates memory from everything else:
    //
    //   0x00_0000 - 0x7F_FFFF  SDRAM, 8 MiB, cacheable (or bypassed)
    //   0x80_0000 - 0x80_07FF  bootrom, 2 KiB, read-only
    //   0x80_1000              control register, 8 bit, read/write
    //
    // Only bits [23] and [12] are decoded, so the bootrom aliases through
    // 0x80_0000-0x80_0FFF and the register through 0x80_1000-0x80_1FFF.
    // Address bits above 23 are ignored.
    // ------------------------------------------------------------------
    localparam int unsigned SYS_ADDR_W = 24;
    localparam int unsigned SYS_MEM_BIT = 23;  // 0 = SDRAM, 1 = peripherals
    localparam int unsigned SYS_CSR_BIT = 12;  // within peripherals: 0 = rom, 1 = csr

    localparam logic [SYS_ADDR_W-1:0] BOOTROM_BASE = 24'h80_0000;
    localparam logic [SYS_ADDR_W-1:0] CSR_BASE = 24'h80_1000;

    // Bootrom depth: 2 KiB (ADDR_W of its native_ram instance).
    localparam int unsigned BOOTROM_ADDR_W = 11;

    // Control register: 8 bits, byte 0 of the addressed word.
    //   [0] CACHE_BYPASS — SDRAM loads and stores go straight to the
    //       device, leaving the cache arrays untouched. Set it while a
    //       loader writes a program into SDRAM, so the program is really
    //       in the device (and not sitting dirty in the D-cache) when the
    //       fetch side goes looking for it. NOT a coherence mechanism:
    //       lines cached before the bit was set stay cached and stale.
    //   [7:1] unused, readable/writable scratch.
    localparam int unsigned CSR_W = 8;
    localparam int unsigned CSR_BIT_BYPASS = 0;

    // Address region a request falls in.
    localparam logic [1:0] RGN_MEM = 2'd0;
    localparam logic [1:0] RGN_BOOT = 2'd1;
    localparam logic [1:0] RGN_CSR = 2'd2;

    function automatic logic [1:0] yarv_region(input logic [NATIVE_ADDR_W-1:0] a);
        if (!a[SYS_MEM_BIT]) yarv_region = RGN_MEM;
        else if (!a[SYS_CSR_BIT]) yarv_region = RGN_BOOT;
        else yarv_region = RGN_CSR;
    endfunction

endpackage

`resetall
