// rv32i_addr_decoder.sv — AXI4-Lite address decoder, 1 master -> 3 slaves.
//
// Demuxes a single AXI4-Lite master port (rv32i_core's LSU) to three
// memory-mapped slaves: a data RAM, uart_axi_periph, and fpu_axi_periph.
// Unmapped addresses get a synthesized DECERR response (no real slave
// exists to generate one).
//
// Address map (4KB regions, decoded on the FULL addr[31:12] page field):
//   0x0000_0000 - 0x0000_03FF : RAM  (axi_lite_slave, NUM_REGS=256, 1KB)
//   0x0000_1000 - 0x0000_10FF : UART (uart_axi_periph, 256B)
//   0x0000_2000 - 0x0000_20FF : FPU  (fpu_axi_periph, 256B)
//   anything else             : DECERR (bresp/rresp = 2'b11)
// Each slave's byte range above is its REAL, distinctly-addressable size
// (RAM/UART/FPU_ADDR_WIDTH), not the full 4KB page -- an address inside a
// slave's 4KB page but above its real ADDR_WIDTH is explicitly routed to
// DECERR (not silently aliased back onto the slave's live registers; see
// the *_in_bounds checks below). An earlier version of this decoder only
// compared awaddr_i[19:12] (8 bits) against the page constants and passed
// awaddr_i[ADDR_WIDTH-1:0] straight through with no bounds check -- caught
// by adversarial review: addr[31:20] silently aliased the whole map every
// 1MB, and any address within a page but past the slave's real width
// silently landed on that slave's low registers with an OKAY response
// instead of DECERR. Both are fixed by decoding the full 20-bit page field
// and gating each page match on an explicit in-bounds check.
//
// Design assumption (explicit, matches the plan's own scope note): the
// only master on this bus is rv32i_core's LSU, which is single-outstanding
// — it never issues a new AW/AR until the current transaction's B/R has
// been observed (see rv32i_lsu.sv's own header comment). This lets each
// channel use one registered select latch (captured at the AW/AR handshake,
// held through B/R) instead of a queue of in-flight selections. The
// write-side DECERR generator still buffers AW and W independently
// (mirroring axi_lite_slave.sv's own aw_pend_q/w_pend_q/commit pattern)
// since AXI4-Lite allows a master to present them on different cycles even
// though this particular master always asserts both together.
`timescale 1ns/1ps

module rv32i_addr_decoder #(
    parameter int DATA_WIDTH     = 32,
    parameter int ADDR_WIDTH     = 32,
    parameter int RAM_ADDR_WIDTH = 10,  // 256 words
    parameter int UART_ADDR_WIDTH = 8,  // 64 words
    parameter int FPU_ADDR_WIDTH  = 8   // 64 words
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // ---------------- Master-facing port (from rv32i_core LSU) ----------------
    input  logic                        awvalid_i,
    output logic                        awready_o,
    input  logic [ADDR_WIDTH-1:0]       awaddr_i,
    input  logic [2:0]                  awprot_i,

    input  logic                        wvalid_i,
    output logic                        wready_o,
    input  logic [DATA_WIDTH-1:0]       wdata_i,
    input  logic [(DATA_WIDTH/8)-1:0]   wstrb_i,

    output logic                        bvalid_o,
    input  logic                        bready_i,
    output logic [1:0]                  bresp_o,

    input  logic                        arvalid_i,
    output logic                        arready_o,
    input  logic [ADDR_WIDTH-1:0]       araddr_i,
    input  logic [2:0]                  arprot_i,

    output logic                        rvalid_o,
    input  logic                        rready_i,
    output logic [DATA_WIDTH-1:0]       rdata_o,
    output logic [1:0]                  rresp_o,

    // ---------------- RAM slave port ----------------
    output logic                        ram_awvalid_o,
    input  logic                        ram_awready_i,
    output logic [RAM_ADDR_WIDTH-1:0]   ram_awaddr_o,
    output logic [2:0]                  ram_awprot_o,
    output logic                        ram_wvalid_o,
    input  logic                        ram_wready_i,
    output logic [DATA_WIDTH-1:0]       ram_wdata_o,
    output logic [(DATA_WIDTH/8)-1:0]   ram_wstrb_o,
    input  logic                        ram_bvalid_i,
    output logic                        ram_bready_o,
    input  logic [1:0]                  ram_bresp_i,
    output logic                        ram_arvalid_o,
    input  logic                        ram_arready_i,
    output logic [RAM_ADDR_WIDTH-1:0]   ram_araddr_o,
    output logic [2:0]                  ram_arprot_o,
    input  logic                        ram_rvalid_i,
    output logic                        ram_rready_o,
    input  logic [DATA_WIDTH-1:0]       ram_rdata_i,
    input  logic [1:0]                  ram_rresp_i,

    // ---------------- UART slave port ----------------
    output logic                        uart_awvalid_o,
    input  logic                        uart_awready_i,
    output logic [UART_ADDR_WIDTH-1:0]  uart_awaddr_o,
    output logic [2:0]                  uart_awprot_o,
    output logic                        uart_wvalid_o,
    input  logic                        uart_wready_i,
    output logic [DATA_WIDTH-1:0]       uart_wdata_o,
    output logic [(DATA_WIDTH/8)-1:0]   uart_wstrb_o,
    input  logic                        uart_bvalid_i,
    output logic                        uart_bready_o,
    input  logic [1:0]                  uart_bresp_i,
    output logic                        uart_arvalid_o,
    input  logic                        uart_arready_i,
    output logic [UART_ADDR_WIDTH-1:0]  uart_araddr_o,
    output logic [2:0]                  uart_arprot_o,
    input  logic                        uart_rvalid_i,
    output logic                        uart_rready_o,
    input  logic [DATA_WIDTH-1:0]       uart_rdata_i,
    input  logic [1:0]                  uart_rresp_i,

    // ---------------- FPU slave port ----------------
    output logic                        fpu_awvalid_o,
    input  logic                        fpu_awready_i,
    output logic [FPU_ADDR_WIDTH-1:0]   fpu_awaddr_o,
    output logic [2:0]                  fpu_awprot_o,
    output logic                        fpu_wvalid_o,
    input  logic                        fpu_wready_i,
    output logic [DATA_WIDTH-1:0]       fpu_wdata_o,
    output logic [(DATA_WIDTH/8)-1:0]   fpu_wstrb_o,
    input  logic                        fpu_bvalid_i,
    output logic                        fpu_bready_o,
    input  logic [1:0]                  fpu_bresp_i,
    output logic                        fpu_arvalid_o,
    input  logic                        fpu_arready_i,
    output logic [FPU_ADDR_WIDTH-1:0]   fpu_araddr_o,
    output logic [2:0]                  fpu_arprot_o,
    input  logic                        fpu_rvalid_i,
    output logic                        fpu_rready_o,
    input  logic [DATA_WIDTH-1:0]       fpu_rdata_i,
    input  logic [1:0]                  fpu_rresp_i
);

    localparam logic [19:0] RAM_PAGE  = 20'h00000;
    localparam logic [19:0] UART_PAGE = 20'h00001;
    localparam logic [19:0] FPU_PAGE  = 20'h00002;

    typedef enum logic [1:0] {SEL_RAM, SEL_UART, SEL_FPU, SEL_NONE} sel_e;

    // -----------------------------------------------------------------
    // Write path
    // -----------------------------------------------------------------
    logic [1:0] wsel_q;
    logic wbusy_q;

    // Icarus rejects a part-select used directly as a case expression
    // ("constant selects in always_* processes are not currently
    // supported") -- an explicit intermediate signal avoids it (same fix
    // as rv32i_lsu.sv's/rv32i_ctrl_decode.sv's addr_byte_sel/branch_cmp_grp).
    wire [19:0] awaddr_page = awaddr_i[31:12];

    // In-bounds within each slave's own real (narrower-than-4KB) address
    // width -- an address inside a slave's page but above its real width
    // routes to DECERR instead of silently aliasing back onto that
    // slave's live registers.
    wire ram_in_bounds  = (awaddr_i[11:RAM_ADDR_WIDTH]  == '0);
    wire uart_in_bounds = (awaddr_i[11:UART_ADDR_WIDTH] == '0);
    wire fpu_in_bounds  = (awaddr_i[11:FPU_ADDR_WIDTH]  == '0);

    logic [1:0] wsel_decode;
    always_comb begin
        unique case (awaddr_page)
            RAM_PAGE:  wsel_decode = ram_in_bounds  ? SEL_RAM  : SEL_NONE;
            UART_PAGE: wsel_decode = uart_in_bounds ? SEL_UART : SEL_NONE;
            FPU_PAGE:  wsel_decode = fpu_in_bounds  ? SEL_FPU  : SEL_NONE;
            default:   wsel_decode = SEL_NONE;
        endcase
    end
    // Plain logic, not sel_e: Icarus requires an explicit cast to assign
    // a ternary of two enum-typed operands into an enum-typed target, but
    // Yosys's frontend rejects that cast's syntax outright (`sel_e'(...)`
    // -> "unexpected TOK_USER_TYPE") -- no cast satisfies both. Comparing
    // a plain 2-bit vector against the sel_e enum constants below works
    // identically (SV compares enum literals by underlying value) and
    // sidesteps the conflict entirely.
    logic [1:0] wsel_active;
    always_comb wsel_active = wbusy_q ? wsel_q : wsel_decode;

    // DECERR write buffer — independent AW/W tracking, commit-based B gen.
    logic decerr_aw_pend_q, decerr_w_pend_q, decerr_bvalid_q;
    wire  decerr_wcommit = decerr_aw_pend_q && decerr_w_pend_q &&
                            (!decerr_bvalid_q || bready_i);

    assign ram_awvalid_o  = awvalid_i && (wsel_active == SEL_RAM);
    assign uart_awvalid_o = awvalid_i && (wsel_active == SEL_UART);
    assign fpu_awvalid_o  = awvalid_i && (wsel_active == SEL_FPU);
    assign ram_awaddr_o   = awaddr_i[RAM_ADDR_WIDTH-1:0];
    assign uart_awaddr_o  = awaddr_i[UART_ADDR_WIDTH-1:0];
    assign fpu_awaddr_o   = awaddr_i[FPU_ADDR_WIDTH-1:0];
    assign ram_awprot_o   = awprot_i;
    assign uart_awprot_o  = awprot_i;
    assign fpu_awprot_o   = awprot_i;

    assign ram_wvalid_o  = wvalid_i && (wsel_active == SEL_RAM);
    assign uart_wvalid_o = wvalid_i && (wsel_active == SEL_UART);
    assign fpu_wvalid_o  = wvalid_i && (wsel_active == SEL_FPU);
    assign ram_wdata_o   = wdata_i;
    assign uart_wdata_o  = wdata_i;
    assign fpu_wdata_o   = wdata_i;
    assign ram_wstrb_o   = wstrb_i;
    assign uart_wstrb_o  = wstrb_i;
    assign fpu_wstrb_o   = wstrb_i;

    assign awready_o = (wsel_active == SEL_RAM)  ? ram_awready_i  :
                        (wsel_active == SEL_UART) ? uart_awready_i :
                        (wsel_active == SEL_FPU)  ? fpu_awready_i  :
                        !decerr_aw_pend_q;

    assign wready_o = (wsel_active == SEL_RAM)  ? ram_wready_i  :
                       (wsel_active == SEL_UART) ? uart_wready_i :
                       (wsel_active == SEL_FPU)  ? fpu_wready_i  :
                       !decerr_w_pend_q;

    // B-channel routing uses the LATCHED select (wsel_q, gated by wbusy_q)
    // rather than wsel_active. wsel_active tracks the live pre-latch decode
    // while idle (wbusy_q=0), which would let a real slave's free-floating
    // bvalid_i leak into bvalid_o whenever awaddr_i happened to point at
    // that slave's region -- even with no write transaction outstanding.
    // Every real slave's own B response is registered at least one cycle
    // after commit (axi_lite_slave.sv's own `bvalid_o <= 1'b1` on commit),
    // so gating strictly on wbusy_q never delays a legitimate response.
    assign bvalid_o = (wsel_q == SEL_RAM)  ? (wbusy_q && ram_bvalid_i)  :
                       (wsel_q == SEL_UART) ? (wbusy_q && uart_bvalid_i) :
                       (wsel_q == SEL_FPU)  ? (wbusy_q && fpu_bvalid_i)  :
                       decerr_bvalid_q;

    assign bresp_o = (wsel_q == SEL_RAM)  ? ram_bresp_i  :
                      (wsel_q == SEL_UART) ? uart_bresp_i :
                      (wsel_q == SEL_FPU)  ? fpu_bresp_i  :
                      2'b11;

    assign ram_bready_o  = bready_i && wbusy_q && (wsel_q == SEL_RAM);
    assign uart_bready_o = bready_i && wbusy_q && (wsel_q == SEL_UART);
    assign fpu_bready_o  = bready_i && wbusy_q && (wsel_q == SEL_FPU);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wbusy_q <= 1'b0;
            wsel_q  <= SEL_NONE;
        end else begin
            if (!wbusy_q && awvalid_i && awready_o) begin
                wbusy_q <= 1'b1;
                wsel_q  <= wsel_decode;
            end else if (wbusy_q && bvalid_o && bready_i) begin
                wbusy_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decerr_aw_pend_q <= 1'b0;
            decerr_w_pend_q  <= 1'b0;
            decerr_bvalid_q  <= 1'b0;
        end else begin
            if (awvalid_i && awready_o && (wsel_active == SEL_NONE))
                decerr_aw_pend_q <= 1'b1;
            else if (decerr_wcommit)
                decerr_aw_pend_q <= 1'b0;

            if (wvalid_i && wready_o && (wsel_active == SEL_NONE))
                decerr_w_pend_q <= 1'b1;
            else if (decerr_wcommit)
                decerr_w_pend_q <= 1'b0;

            if (decerr_wcommit)
                decerr_bvalid_q <= 1'b1;
            else if (decerr_bvalid_q && bready_i)
                decerr_bvalid_q <= 1'b0;
        end
    end

    // -----------------------------------------------------------------
    // Read path
    // -----------------------------------------------------------------
    logic [1:0] rsel_q;
    logic rbusy_q;

    wire [19:0] araddr_page = araddr_i[31:12];

    wire ram_ar_in_bounds  = (araddr_i[11:RAM_ADDR_WIDTH]  == '0);
    wire uart_ar_in_bounds = (araddr_i[11:UART_ADDR_WIDTH] == '0);
    wire fpu_ar_in_bounds  = (araddr_i[11:FPU_ADDR_WIDTH]  == '0);

    logic [1:0] rsel_decode;
    always_comb begin
        unique case (araddr_page)
            RAM_PAGE:  rsel_decode = ram_ar_in_bounds  ? SEL_RAM  : SEL_NONE;
            UART_PAGE: rsel_decode = uart_ar_in_bounds ? SEL_UART : SEL_NONE;
            FPU_PAGE:  rsel_decode = fpu_ar_in_bounds  ? SEL_FPU  : SEL_NONE;
            default:   rsel_decode = SEL_NONE;
        endcase
    end
    logic [1:0] rsel_active;
    always_comb rsel_active = rbusy_q ? rsel_q : rsel_decode;

    logic decerr_rvalid_q;

    assign ram_arvalid_o  = arvalid_i && (rsel_active == SEL_RAM);
    assign uart_arvalid_o = arvalid_i && (rsel_active == SEL_UART);
    assign fpu_arvalid_o  = arvalid_i && (rsel_active == SEL_FPU);
    assign ram_araddr_o   = araddr_i[RAM_ADDR_WIDTH-1:0];
    assign uart_araddr_o  = araddr_i[UART_ADDR_WIDTH-1:0];
    assign fpu_araddr_o   = araddr_i[FPU_ADDR_WIDTH-1:0];
    assign ram_arprot_o   = arprot_i;
    assign uart_arprot_o  = arprot_i;
    assign fpu_arprot_o   = arprot_i;

    assign arready_o = (rsel_active == SEL_RAM)  ? ram_arready_i  :
                        (rsel_active == SEL_UART) ? uart_arready_i :
                        (rsel_active == SEL_FPU)  ? fpu_arready_i  :
                        !(rbusy_q && rsel_q == SEL_NONE);

    // Same fix as the B channel: gate real-slave R routing on the latched
    // rbusy_q/rsel_q, not the live pre-latch rsel_active.
    assign rvalid_o = (rsel_q == SEL_RAM)  ? (rbusy_q && ram_rvalid_i)  :
                       (rsel_q == SEL_UART) ? (rbusy_q && uart_rvalid_i) :
                       (rsel_q == SEL_FPU)  ? (rbusy_q && fpu_rvalid_i)  :
                       decerr_rvalid_q;

    assign rdata_o = (rsel_q == SEL_RAM)  ? ram_rdata_i  :
                      (rsel_q == SEL_UART) ? uart_rdata_i :
                      (rsel_q == SEL_FPU)  ? fpu_rdata_i  :
                      '0;

    assign rresp_o = (rsel_q == SEL_RAM)  ? ram_rresp_i  :
                      (rsel_q == SEL_UART) ? uart_rresp_i :
                      (rsel_q == SEL_FPU)  ? fpu_rresp_i  :
                      2'b11;

    assign ram_rready_o  = rready_i && rbusy_q && (rsel_q == SEL_RAM);
    assign uart_rready_o = rready_i && rbusy_q && (rsel_q == SEL_UART);
    assign fpu_rready_o  = rready_i && rbusy_q && (rsel_q == SEL_FPU);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rbusy_q <= 1'b0;
            rsel_q  <= SEL_NONE;
        end else begin
            if (!rbusy_q && arvalid_i && arready_o) begin
                rbusy_q <= 1'b1;
                rsel_q  <= rsel_decode;
            end else if (rbusy_q && rvalid_o && rready_i) begin
                rbusy_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decerr_rvalid_q <= 1'b0;
        end else begin
            if (arvalid_i && arready_o && (rsel_active == SEL_NONE))
                decerr_rvalid_q <= 1'b1;
            else if (decerr_rvalid_q && rready_i)
                decerr_rvalid_q <= 1'b0;
        end
    end

    // -----------------------------------------------------------------
    // Formal verification — decoder correctness only (routing/DECERR),
    // not the real slaves (anyseq-stubbed, matching this repo's usual
    // per-checkpoint idiom for composed modules with proven leaves).
    // -----------------------------------------------------------------
`ifdef FORMAL
    initial assume(!rst_n);

    // This decoder's only master is rv32i_core's LSU, which is explicitly
    // single-outstanding (see rv32i_lsu.sv's own header comment: it never
    // asserts awvalid_o/arvalid_o for a new request until the previous
    // transaction's B/R has been observed). Without assuming that here, the
    // free (unconstrained) awvalid_i/awaddr_i formal inputs can present a
    // SECOND, unrelated address while wbusy_q is still 1 -- the combinational
    // aw*_o passthroughs (e.g. fpu_awaddr_o = awaddr_i[...]) would forward
    // that bogus address to whichever slave wsel_q already points at, mid-
    // transaction. A decoder robust to a fully general (multi-outstanding)
    // master would need its own AW/W skid buffers, duplicating what every
    // real slave already does -- unneeded complexity given the plan's own
    // stated scope: "explicitly simplified to assume a single-outstanding-
    // transaction master."
    always_comb begin
        if (rst_n) begin
            assume(!(wbusy_q && awvalid_i));
            assume(!(rbusy_q && arvalid_i));
        end
    end

    // The 3 real slaves are each proven standalone (axi_lite_slave.sv's own
    // formal block, inherited by fpu_axi_periph/uart_axi_periph) to hold
    // their bvalid_o/rvalid_o high until the matching ready fires (AXI4-Lite
    // VALID-sticky, §A3.2.1). In THIS standalone proof, ram_bvalid_i/
    // uart_bvalid_i/fpu_bvalid_i/*_rvalid_i are free (unconstrained) formal
    // inputs -- without assuming the same discipline on them, the solver can
    // pick a slave input trace that drops VALID mid-transaction, producing a
    // counterexample against a real slave's own guarantee, not a decoder
    // bug. Mirrors rv32i_lsu.sv's own note: "assumes exactly this discipline
    // from whatever [slave/master] it's attached to."
    logic f_ram_bvalid_d, f_ram_bready_d, f_uart_bvalid_d, f_uart_bready_d;
    logic f_fpu_bvalid_d, f_fpu_bready_d;
    logic f_ram_rvalid_d, f_ram_rready_d, f_uart_rvalid_d, f_uart_rready_d;
    logic f_fpu_rvalid_d, f_fpu_rready_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_ram_bvalid_d  <= 1'b0; f_ram_bready_d  <= 1'b0;
            f_uart_bvalid_d <= 1'b0; f_uart_bready_d <= 1'b0;
            f_fpu_bvalid_d  <= 1'b0; f_fpu_bready_d  <= 1'b0;
            f_ram_rvalid_d  <= 1'b0; f_ram_rready_d  <= 1'b0;
            f_uart_rvalid_d <= 1'b0; f_uart_rready_d <= 1'b0;
            f_fpu_rvalid_d  <= 1'b0; f_fpu_rready_d  <= 1'b0;
        end else begin
            f_ram_bvalid_d  <= ram_bvalid_i;  f_ram_bready_d  <= ram_bready_o;
            f_uart_bvalid_d <= uart_bvalid_i; f_uart_bready_d <= uart_bready_o;
            f_fpu_bvalid_d  <= fpu_bvalid_i;  f_fpu_bready_d  <= fpu_bready_o;
            f_ram_rvalid_d  <= ram_rvalid_i;  f_ram_rready_d  <= ram_rready_o;
            f_uart_rvalid_d <= uart_rvalid_i; f_uart_rready_d <= uart_rready_o;
            f_fpu_rvalid_d  <= fpu_rvalid_i;  f_fpu_rready_d  <= fpu_rready_o;
        end
    end
    always_comb begin
        if (rst_n) begin
            if (f_ram_bvalid_d  && !f_ram_bready_d)  assume(ram_bvalid_i);
            if (f_uart_bvalid_d && !f_uart_bready_d) assume(uart_bvalid_i);
            if (f_fpu_bvalid_d  && !f_fpu_bready_d)  assume(fpu_bvalid_i);
            if (f_ram_rvalid_d  && !f_ram_rready_d)  assume(ram_rvalid_i);
            if (f_uart_rvalid_d && !f_uart_rready_d) assume(uart_rvalid_i);
            if (f_fpu_rvalid_d  && !f_fpu_rready_d)  assume(fpu_rvalid_i);
        end
    end

    always_comb begin
        if (rst_n) begin
            // Exactly one slave (or none, for DECERR) ever gets awvalid/arvalid.
            assert($onehot0({ram_awvalid_o, uart_awvalid_o, fpu_awvalid_o}));
            assert($onehot0({ram_arvalid_o, uart_arvalid_o, fpu_arvalid_o}));

            // DECERR is exact: bresp/rresp == 2'b11 iff the active selection is NONE.
            if (wbusy_q && wsel_q == SEL_NONE) begin
                if (decerr_bvalid_q) assert(bresp_o == 2'b11);
            end
            if (rbusy_q && rsel_q == SEL_NONE) begin
                if (decerr_rvalid_q) assert(rresp_o == 2'b11);
            end

            // No real slave ever sees a request routed to a different slave's B/R.
            assert(!(ram_bready_o && uart_bready_o));
            assert(!(ram_bready_o && fpu_bready_o));
            assert(!(uart_bready_o && fpu_bready_o));
        end
    end

    // Real (non-tautological) address-to-slave mapping properties. The
    // page literals here are hardcoded directly, NOT reusing this file's
    // own RAM_PAGE/UART_PAGE/FPU_PAGE localparams. Reusing those would
    // make the property trivially self-consistent even if all three
    // localparams were swapped together -- the case statement and the
    // property would still agree with each other, just both wrong
    // relative to the documented map. This is exactly the vacuous-proof
    // gap an adversarial review caught in an earlier version of this
    // proof: the $onehot0/DECERR-format properties above hold regardless
    // of whether RAM_PAGE and UART_PAGE are swapped, so they never
    // actually verified routing correctness, only routing exclusivity.
    // Pinning literal values here means a future edit that swaps the page
    // assignment (in either the case statement or the localparams) breaks
    // this property immediately, the way it should. Also directly checks
    // the in-bounds gating (an in-page-but-out-of-range address must
    // route to DECERR, not the real slave).
    always_comb begin
        if (rst_n) begin
            if (awaddr_page == 20'h00000 && ram_in_bounds)   assert(wsel_decode == SEL_RAM);
            if (awaddr_page == 20'h00001 && uart_in_bounds)  assert(wsel_decode == SEL_UART);
            if (awaddr_page == 20'h00002 && fpu_in_bounds)   assert(wsel_decode == SEL_FPU);
            if (awaddr_page > 20'h00002)                     assert(wsel_decode == SEL_NONE);
            if (awaddr_page == 20'h00000 && !ram_in_bounds)  assert(wsel_decode == SEL_NONE);
            if (awaddr_page == 20'h00001 && !uart_in_bounds) assert(wsel_decode == SEL_NONE);
            if (awaddr_page == 20'h00002 && !fpu_in_bounds)  assert(wsel_decode == SEL_NONE);

            if (araddr_page == 20'h00000 && ram_ar_in_bounds)   assert(rsel_decode == SEL_RAM);
            if (araddr_page == 20'h00001 && uart_ar_in_bounds)  assert(rsel_decode == SEL_UART);
            if (araddr_page == 20'h00002 && fpu_ar_in_bounds)   assert(rsel_decode == SEL_FPU);
            if (araddr_page > 20'h00002)                        assert(rsel_decode == SEL_NONE);
            if (araddr_page == 20'h00000 && !ram_ar_in_bounds)  assert(rsel_decode == SEL_NONE);
            if (araddr_page == 20'h00001 && !uart_ar_in_bounds) assert(rsel_decode == SEL_NONE);
            if (araddr_page == 20'h00002 && !fpu_ar_in_bounds)  assert(rsel_decode == SEL_NONE);
        end
    end

    // VALID-sticky on the DECERR-generated responses (same idiom as
    // axi_lite_slave.sv's own formal block).
    logic f_bvalid_d, f_bready_d, f_rvalid_d, f_rready_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_bvalid_d <= 1'b0; f_bready_d <= 1'b0;
            f_rvalid_d <= 1'b0; f_rready_d <= 1'b0;
        end else begin
            f_bvalid_d <= bvalid_o; f_bready_d <= bready_i;
            f_rvalid_d <= rvalid_o; f_rready_d <= rready_i;
        end
    end
    always_comb begin
        if (rst_n) begin
            if (f_bvalid_d && !f_bready_d) assert(bvalid_o);
            if (f_rvalid_d && !f_rready_d) assert(rvalid_o);
        end
    end

    always_comb begin
        cover(rst_n && bvalid_o && bready_i && bresp_o == 2'b11);  // DECERR write reachable
        cover(rst_n && rvalid_o && rready_i && rresp_o == 2'b11);  // DECERR read reachable
        cover(rst_n && ram_bvalid_i && ram_bready_o);              // RAM write reachable
        cover(rst_n && uart_bvalid_i && uart_bready_o);            // UART write reachable
        cover(rst_n && fpu_bvalid_i && fpu_bready_o);              // FPU write reachable

        // In-page-but-out-of-bounds DECERR is a real, reachable branch,
        // not one the bounds check vacuously eliminates.
        cover(rst_n && awvalid_i && awaddr_page == 20'h00000 && !ram_in_bounds);
        cover(rst_n && awvalid_i && awaddr_page == 20'h00001 && !uart_in_bounds);
        cover(rst_n && awvalid_i && awaddr_page == 20'h00002 && !fpu_in_bounds);
    end
`endif

endmodule
