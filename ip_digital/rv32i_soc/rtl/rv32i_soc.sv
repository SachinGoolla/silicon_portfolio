// rv32i_soc.sv — RISC-V SoC top level: rv32i_core + rv32i_addr_decoder +
// a data RAM (axi_lite_slave reused directly, see below) + uart_axi_periph
// + fpu_axi_periph + the real instruction ROM (rv32i_soc_imem.sv, generated
// by scripts/rv32i_asm.py --format rom from verification/program.s).
//
// Flat-copy composition (this repo's established pattern for composed IPs,
// e.g. fpu_axi_periph/rtl/ containing a full copy of fpu_top.sv and its
// transitive closure, not a manifest reference) — every submodule's RTL is
// copied into this IP's own rtl/, not referenced from its origin IP.
//
// RAM peripheral: rather than a new purpose-built module, this instantiates
// axi_lite_slave directly (NUM_REGS=256, 1KB) with its HW-write side channel
// tied off (hw_we_i='0). axi_lite_slave already provides everything a plain
// SW-read/write RAM needs on this bus -- WSTRB byte-lane masking, SLVERR on
// out-of-range, independent AW/W buffering -- and is already proven
// standalone (its own formal block). Building a second, separate RAM module
// would just re-implement the same register file this IP already has.
//
// Address map (see rv32i_addr_decoder.sv for the authoritative decode):
//   0x0000_0000-0x0000_0FFF RAM  (256 words / 1KB used)
//   0x0000_1000-0x0000_1FFF UART (uart_axi_periph)
//   0x0000_2000-0x0000_2FFF FPU  (fpu_axi_periph)
//   anything else            DECERR
`timescale 1ns/1ps

// CLK_FREQ/BAUD_RATE default to the fast-sim values (BRDIV_VAL=0, see
// apb_uart_master's own CLAUDE.md) rather than realistic 50MHz/115200 --
// deliberately DIFFERENT from uart_axi_periph's own choice (realistic
// defaults there, fast-sim only via a TB-level override / cocotb_sim.mk).
// uart_axi_periph is a reusable peripheral instantiated by other designs
// with their own real clocking; rv32i_soc is a top-level SoC whose only
// purpose is running the fixed program baked into rv32i_soc_imem.sv under
// THIS portfolio's own 9-pillar flow -- there is no external integrator
// who'd want a different default. This also sidesteps a real problem: a
// synthesized netlist has no parameters left to override (confirmed via a
// real P8 GLS elaboration failure, "parameter CLK_FREQ not found in
// tb_rv32i_soc.u_dut" -- Icarus errors outright, doesn't silently ignore
// the override), so whatever value is active AT SYNTHESIS TIME is what
// every downstream pillar (P6 synthesis, P7 LEC, P8 GLS) is permanently
// stuck with. Making the default itself fast-sim means P3/P4/P6/P7/P8 all
// see the identical, tractable timing with no per-pillar special-casing.
module rv32i_soc #(
    parameter int RAM_NUM_REGS = 256,
    parameter int CLK_FREQ     = 1600,
    parameter int BAUD_RATE    = 100
) (
    input  logic clk,
    input  logic rst_n,

    output logic uart_tx_o,
    input  logic uart_rx_i
);

    // -----------------------------------------------------------------
    // CPU <-> instruction ROM
    // -----------------------------------------------------------------
    logic [31:0] imem_addr;
    logic [31:0] imem_rdata;

    rv32i_soc_imem u_imem (
        .addr_i  (imem_addr),
        .rdata_o (imem_rdata)
    );

    // -----------------------------------------------------------------
    // CPU <-> address decoder (master side)
    // -----------------------------------------------------------------
    logic        cpu_awvalid, cpu_awready;
    logic [31:0] cpu_awaddr;
    logic [2:0]  cpu_awprot;
    logic        cpu_wvalid, cpu_wready;
    logic [31:0] cpu_wdata;
    logic [3:0]  cpu_wstrb;
    logic        cpu_bvalid, cpu_bready;
    logic [1:0]  cpu_bresp;
    logic        cpu_arvalid, cpu_arready;
    logic [31:0] cpu_araddr;
    logic [2:0]  cpu_arprot;
    logic        cpu_rvalid, cpu_rready;
    logic [31:0] cpu_rdata;
    logic [1:0]  cpu_rresp;

    rv32i_core u_core (
        .clk          (clk),
        .rst_n        (rst_n),
        .imem_addr_o  (imem_addr),
        .imem_rdata_i (imem_rdata),
        .awvalid_o    (cpu_awvalid),
        .awready_i    (cpu_awready),
        .awaddr_o     (cpu_awaddr),
        .awprot_o     (cpu_awprot),
        .wvalid_o     (cpu_wvalid),
        .wready_i     (cpu_wready),
        .wdata_o      (cpu_wdata),
        .wstrb_o      (cpu_wstrb),
        .bvalid_i     (cpu_bvalid),
        .bready_o     (cpu_bready),
        .bresp_i      (cpu_bresp),
        .arvalid_o    (cpu_arvalid),
        .arready_i    (cpu_arready),
        .araddr_o     (cpu_araddr),
        .arprot_o     (cpu_arprot),
        .rvalid_i     (cpu_rvalid),
        .rready_o     (cpu_rready),
        .rdata_i      (cpu_rdata),
        .rresp_i      (cpu_rresp)
    );

    // -----------------------------------------------------------------
    // Address decoder <-> RAM (axi_lite_slave)
    // -----------------------------------------------------------------
    localparam int RAM_ADDR_WIDTH = $clog2(RAM_NUM_REGS * 4);

    logic                    ram_awvalid, ram_awready;
    logic [RAM_ADDR_WIDTH-1:0] ram_awaddr;
    logic [2:0]               ram_awprot;
    logic                     ram_wvalid, ram_wready;
    logic [31:0]              ram_wdata;
    logic [3:0]               ram_wstrb;
    logic                     ram_bvalid, ram_bready;
    logic [1:0]               ram_bresp;
    logic                     ram_arvalid, ram_arready;
    logic [RAM_ADDR_WIDTH-1:0] ram_araddr;
    logic [2:0]               ram_arprot;
    logic                     ram_rvalid, ram_rready;
    logic [31:0]              ram_rdata;
    logic [1:0]               ram_rresp;

    axi_lite_slave #(
        .DATA_WIDTH (32),
        .ADDR_WIDTH (RAM_ADDR_WIDTH),
        .NUM_REGS   (RAM_NUM_REGS)
    ) u_ram (
        .clk        (clk),
        .rst_n      (rst_n),
        .awvalid_i  (ram_awvalid),
        .awready_o  (ram_awready),
        .awaddr_i   (ram_awaddr),
        .awprot_i   (ram_awprot),
        .wvalid_i   (ram_wvalid),
        .wready_o   (ram_wready),
        .wdata_i    (ram_wdata),
        .wstrb_i    (ram_wstrb),
        .bvalid_o   (ram_bvalid),
        .bready_i   (ram_bready),
        .bresp_o    (ram_bresp),
        .arvalid_i  (ram_arvalid),
        .arready_o  (ram_arready),
        .araddr_i   (ram_araddr),
        .arprot_i   (ram_arprot),
        .rvalid_o   (ram_rvalid),
        .rready_i   (ram_rready),
        .rdata_o    (ram_rdata),
        .rresp_o    (ram_rresp),
        /* verilator lint_off PINCONNECTEMPTY */
        .regfile_o  (),  // plain SW RAM -- no HW read-side consumer
        .reg_we_o   (),  // plain SW RAM -- no HW write-enable consumer
        /* verilator lint_on PINCONNECTEMPTY */
        .hw_wdata_i ('0),
        .hw_we_i    ('0)
    );

    // -----------------------------------------------------------------
    // Address decoder <-> UART peripheral
    // -----------------------------------------------------------------
    logic        uart_awvalid, uart_awready;
    logic [7:0]  uart_awaddr;
    logic [2:0]  uart_awprot;
    logic        uart_wvalid, uart_wready;
    logic [31:0] uart_wdata;
    logic [3:0]  uart_wstrb;
    logic        uart_bvalid, uart_bready;
    logic [1:0]  uart_bresp;
    logic        uart_arvalid, uart_arready;
    logic [7:0]  uart_araddr;
    logic [2:0]  uart_arprot;
    logic        uart_rvalid, uart_rready;
    logic [31:0] uart_rdata;
    logic [1:0]  uart_rresp;

    uart_axi_periph #(
        .DATA_WIDTH (32),
        .ADDR_WIDTH (8),
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_uart (
        .clk        (clk),
        .rst_n      (rst_n),
        .awvalid_i  (uart_awvalid),
        .awready_o  (uart_awready),
        .awaddr_i   (uart_awaddr),
        .awprot_i   (uart_awprot),
        .wvalid_i   (uart_wvalid),
        .wready_o   (uart_wready),
        .wdata_i    (uart_wdata),
        .wstrb_i    (uart_wstrb),
        .bvalid_o   (uart_bvalid),
        .bready_i   (uart_bready),
        .bresp_o    (uart_bresp),
        .arvalid_i  (uart_arvalid),
        .arready_o  (uart_arready),
        .araddr_i   (uart_araddr),
        .arprot_i   (uart_arprot),
        .rvalid_o   (uart_rvalid),
        .rready_i   (uart_rready),
        .rdata_o    (uart_rdata),
        .rresp_o    (uart_rresp),
        .uart_tx_o  (uart_tx_o),
        .uart_rx_i  (uart_rx_i)
    );

    // -----------------------------------------------------------------
    // Address decoder <-> FPU peripheral
    // -----------------------------------------------------------------
    logic        fpu_awvalid, fpu_awready;
    logic [7:0]  fpu_awaddr;
    logic [2:0]  fpu_awprot;
    logic        fpu_wvalid, fpu_wready;
    logic [31:0] fpu_wdata;
    logic [3:0]  fpu_wstrb;
    logic        fpu_bvalid, fpu_bready;
    logic [1:0]  fpu_bresp;
    logic        fpu_arvalid, fpu_arready;
    logic [7:0]  fpu_araddr;
    logic [2:0]  fpu_arprot;
    logic        fpu_rvalid, fpu_rready;
    logic [31:0] fpu_rdata;
    logic [1:0]  fpu_rresp;

    fpu_axi_periph #(
        .DATA_WIDTH (32),
        .ADDR_WIDTH (8),
        .FLEN       (32),
        .XLEN       (32)
    ) u_fpu (
        .clk        (clk),
        .rst_n      (rst_n),
        .awvalid_i  (fpu_awvalid),
        .awready_o  (fpu_awready),
        .awaddr_i   (fpu_awaddr),
        .awprot_i   (fpu_awprot),
        .wvalid_i   (fpu_wvalid),
        .wready_o   (fpu_wready),
        .wdata_i    (fpu_wdata),
        .wstrb_i    (fpu_wstrb),
        .bvalid_o   (fpu_bvalid),
        .bready_i   (fpu_bready),
        .bresp_o    (fpu_bresp),
        .arvalid_i  (fpu_arvalid),
        .arready_o  (fpu_arready),
        .araddr_i   (fpu_araddr),
        .arprot_i   (fpu_arprot),
        .rvalid_o   (fpu_rvalid),
        .rready_i   (fpu_rready),
        .rdata_o    (fpu_rdata),
        .rresp_o    (fpu_rresp)
    );

    // -----------------------------------------------------------------
    // Address decoder — demuxes the CPU's single AXI4-Lite master port
    // to the 3 slaves above.
    // -----------------------------------------------------------------
    rv32i_addr_decoder #(
        .DATA_WIDTH      (32),
        .ADDR_WIDTH      (32),
        .RAM_ADDR_WIDTH  (RAM_ADDR_WIDTH),
        .UART_ADDR_WIDTH (8),
        .FPU_ADDR_WIDTH  (8)
    ) u_decoder (
        .clk            (clk),
        .rst_n          (rst_n),

        .awvalid_i      (cpu_awvalid),
        .awready_o      (cpu_awready),
        .awaddr_i       (cpu_awaddr),
        .awprot_i       (cpu_awprot),
        .wvalid_i       (cpu_wvalid),
        .wready_o       (cpu_wready),
        .wdata_i        (cpu_wdata),
        .wstrb_i        (cpu_wstrb),
        .bvalid_o       (cpu_bvalid),
        .bready_i       (cpu_bready),
        .bresp_o        (cpu_bresp),
        .arvalid_i      (cpu_arvalid),
        .arready_o      (cpu_arready),
        .araddr_i       (cpu_araddr),
        .arprot_i       (cpu_arprot),
        .rvalid_o       (cpu_rvalid),
        .rready_i       (cpu_rready),
        .rdata_o        (cpu_rdata),
        .rresp_o        (cpu_rresp),

        .ram_awvalid_o  (ram_awvalid),
        .ram_awready_i  (ram_awready),
        .ram_awaddr_o   (ram_awaddr),
        .ram_awprot_o   (ram_awprot),
        .ram_wvalid_o   (ram_wvalid),
        .ram_wready_i   (ram_wready),
        .ram_wdata_o    (ram_wdata),
        .ram_wstrb_o    (ram_wstrb),
        .ram_bvalid_i   (ram_bvalid),
        .ram_bready_o   (ram_bready),
        .ram_bresp_i    (ram_bresp),
        .ram_arvalid_o  (ram_arvalid),
        .ram_arready_i  (ram_arready),
        .ram_araddr_o   (ram_araddr),
        .ram_arprot_o   (ram_arprot),
        .ram_rvalid_i   (ram_rvalid),
        .ram_rready_o   (ram_rready),
        .ram_rdata_i    (ram_rdata),
        .ram_rresp_i    (ram_rresp),

        .uart_awvalid_o (uart_awvalid),
        .uart_awready_i (uart_awready),
        .uart_awaddr_o  (uart_awaddr),
        .uart_awprot_o  (uart_awprot),
        .uart_wvalid_o  (uart_wvalid),
        .uart_wready_i  (uart_wready),
        .uart_wdata_o   (uart_wdata),
        .uart_wstrb_o   (uart_wstrb),
        .uart_bvalid_i  (uart_bvalid),
        .uart_bready_o  (uart_bready),
        .uart_bresp_i   (uart_bresp),
        .uart_arvalid_o (uart_arvalid),
        .uart_arready_i (uart_arready),
        .uart_araddr_o  (uart_araddr),
        .uart_arprot_o  (uart_arprot),
        .uart_rvalid_i  (uart_rvalid),
        .uart_rready_o  (uart_rready),
        .uart_rdata_i   (uart_rdata),
        .uart_rresp_i   (uart_rresp),

        .fpu_awvalid_o  (fpu_awvalid),
        .fpu_awready_i  (fpu_awready),
        .fpu_awaddr_o   (fpu_awaddr),
        .fpu_awprot_o   (fpu_awprot),
        .fpu_wvalid_o   (fpu_wvalid),
        .fpu_wready_i   (fpu_wready),
        .fpu_wdata_o    (fpu_wdata),
        .fpu_wstrb_o    (fpu_wstrb),
        .fpu_bvalid_i   (fpu_bvalid),
        .fpu_bready_o   (fpu_bready),
        .fpu_bresp_i    (fpu_bresp),
        .fpu_arvalid_o  (fpu_arvalid),
        .fpu_arready_i  (fpu_arready),
        .fpu_araddr_o   (fpu_araddr),
        .fpu_arprot_o   (fpu_arprot),
        .fpu_rvalid_i   (fpu_rvalid),
        .fpu_rready_o   (fpu_rready),
        .fpu_rdata_i    (fpu_rdata),
        .fpu_rresp_i    (fpu_rresp)
    );

endmodule
