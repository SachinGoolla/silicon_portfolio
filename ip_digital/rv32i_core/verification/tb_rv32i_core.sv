// tb_rv32i_core.sv — self-checking testbench for rv32i_core, used by
// Pillar 4 (Verilator sim/coverage) and Pillar 8 (GLS). Instantiates the
// core against imem_stub.sv (the Python-generated test program) and
// axi_lite_mem_bfm.sv (a small AXI4-Lite RAM with deliberate multi-cycle
// handshake latency), runs to completion, and checks final memory state
// against golden values computed independently in golden_values.py (see
// that script's docstring for why -- same encode/verify separation
// gen_test_program.py's own oracle discipline uses).
//
// imem_stub.sv/axi_lite_mem_bfm.sv are `include`d (not just instantiated)
// deliberately: neither p4_sim.py's Verilator invocation nor
// p8_sta_gls.py's Icarus invocation glob verification/ for extra
// TB-support modules beyond the tb_*.sv file itself (verified by reading
// both) -- every other IP's testbench in this portfolio is self-contained
// with no separate DUT-adjacent helper module, so this need never came up
// before. `include pulls each file's module definition into THIS
// compilation unit directly, needing no pillar.py changes -- safer than
// teaching shared infra a new per-IP file-discovery rule for what is, so
// far, a single IP's requirement.
`timescale 1ns/1ps

`include "ip_digital/rv32i_core/verification/imem_stub.sv"
`include "ip_digital/rv32i_core/verification/axi_lite_mem_bfm.sv"

module tb_rv32i_core;

    logic clk = 0;
    logic rst_n = 0;

    always #5 clk = ~clk;  // 10 ns period, sim-speed only (not the SDC's 20 ns)

    logic [31:0] imem_addr, imem_rdata;

    logic        awvalid, awready;
    logic [31:0] awaddr;
    logic [2:0]  awprot;
    logic        wvalid, wready;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        bvalid, bready;
    logic [1:0]  bresp;
    logic        arvalid, arready;
    logic [31:0] araddr;
    logic [2:0]  arprot;
    logic        rvalid, rready;
    logic [31:0] rdata;
    logic [1:0]  rresp;

    rv32i_core u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .imem_addr_o  (imem_addr),
        .imem_rdata_i (imem_rdata),
        .awvalid_o (awvalid), .awready_i (awready), .awaddr_o (awaddr), .awprot_o (awprot),
        .wvalid_o  (wvalid),  .wready_i  (wready),  .wdata_o  (wdata),  .wstrb_o  (wstrb),
        .bvalid_i  (bvalid),  .bready_o  (bready),  .bresp_i  (bresp),
        .arvalid_o (arvalid), .arready_i (arready), .araddr_o (araddr), .arprot_o (arprot),
        .rvalid_i  (rvalid),  .rready_o  (rready),  .rdata_i  (rdata),  .rresp_i  (rresp)
    );

    imem_stub u_imem (
        .addr_i  (imem_addr),
        .rdata_o (imem_rdata)
    );

    axi_lite_mem_bfm #(.MEM_WORDS(128)) u_bfm (
        .clk (clk), .rst_n (rst_n),
        .awvalid_i (awvalid), .awready_o (awready), .awaddr_i (awaddr), .awprot_i (awprot),
        .wvalid_i  (wvalid),  .wready_o  (wready),  .wdata_i  (wdata),  .wstrb_i  (wstrb),
        .bvalid_o  (bvalid),  .bready_i  (bready),  .bresp_o  (bresp),
        .arvalid_i (arvalid), .arready_o (arready), .araddr_i (araddr), .arprot_i (arprot),
        .rvalid_o  (rvalid),  .rready_i  (rready),  .rdata_o  (rdata),  .rresp_o  (rresp)
    );

    initial begin
        $dumpfile("sim_rv32i_core.fst");
        $dumpvars(0, tb_rv32i_core);
    end

    // Wall-clock watchdog, independent of the cycle-counted MAX_CYCLES
    // poll below — belt-and-suspenders against a hang, same pattern as
    // tb_uart_axi_periph.sv's own timeout block.
    initial begin
        #2_000_000;
        $error("SIMULATION TIMEOUT");
        $finish;
    end

    // -----------------------------------------------------------------
    // Golden values -- computed independently by golden_values.py, not
    // hand-derived here. Regenerate with `python3 golden_values.py` if
    // gen_test_program.py's program ever changes.
    // -----------------------------------------------------------------
    localparam int NCHECK = 11;
    int          golden_addr [0:NCHECK-1];
    logic [31:0] golden_data [0:NCHECK-1];

    initial begin
        // Icarus doesn't support SV array-literal ('{...}) initializers on
        // a declaration -- explicit indexed assignment instead.
        golden_addr[0]  = 0;   golden_data[0]  = 32'h0000000C;
        golden_addr[1]  = 4;   golden_data[1]  = 32'h0000000A;
        golden_addr[2]  = 8;   golden_data[2]  = 32'h00000005;
        golden_addr[3]  = 12;  golden_data[3]  = 32'h00000002;
        golden_addr[4]  = 16;  golden_data[4]  = 32'h00000018;
        golden_addr[5]  = 20;  golden_data[5]  = 32'h00000063;
        golden_addr[6]  = 24;  golden_data[6]  = 32'h000000C8;
        golden_addr[7]  = 28;  golden_data[7]  = 32'h000000E0;
        golden_addr[8]  = 32;  golden_data[8]  = 32'h12345000;
        golden_addr[9]  = 36;  golden_data[9]  = 32'h0000004C;
        golden_addr[10] = 100; golden_data[10] = 32'h00000001;
    end

    integer errors;
    integer cycles;
    localparam int MAX_CYCLES = 2000;

    initial begin
        errors = 0;
        cycles = 0;

        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // Poll mem[100] (the DONE sentinel) for the program's final write.
        while (u_bfm.mem[25] == 32'd0 && cycles < MAX_CYCLES) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        if (cycles >= MAX_CYCLES) begin
            $display("TB_RV32I_CORE: TIMEOUT after %0d cycles waiting for DONE sentinel", MAX_CYCLES);
            errors = errors + 1;
        end else begin
            $display("TB_RV32I_CORE: DONE sentinel observed after %0d cycles", cycles);
            repeat (4) @(posedge clk);  // let any trailing writeback settle

            for (int i = 0; i < NCHECK; i++) begin
                logic [6:0] word_idx;  // u_bfm.mem is [0:127] -- 7-bit index
                logic [31:0] got;
                word_idx = golden_addr[i][8:2];
                got = u_bfm.mem[word_idx];
                if (got !== golden_data[i]) begin
                    $display("TB_RV32I_CORE: MISMATCH mem[%0d] = 32'h%08x, expected 32'h%08x",
                              golden_addr[i], got, golden_data[i]);
                    errors = errors + 1;
                end else begin
                    $display("TB_RV32I_CORE: OK      mem[%0d] = 32'h%08x", golden_addr[i], got);
                end
            end
        end

        if (errors == 0) begin
            $display("TB_RV32I_CORE: PASS -- all %0d checks matched", NCHECK);
        end else begin
            $display("TB_RV32I_CORE: FAIL -- %0d error(s)", errors);
            $error("rv32i_core self-check failed");
        end

        $finish;
    end

endmodule
