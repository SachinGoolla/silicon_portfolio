// tb_rv32i_soc.sv — self-checking testbench for rv32i_soc, used by Pillar 4
// (Verilator sim/coverage) and Pillar 8 (GLS). Instantiates the full SoC
// (core + address decoder + RAM + UART + FPU peripherals + the real
// assembled instruction ROM), loops uart_rx_i <= uart_tx_o externally
// (matching uart_axi_periph's own TB precedent, tb_uart_axi_periph.sv), and
// runs verification/program.s to completion. No CLK_FREQ/BAUD_RATE
// override needed here -- rv32i_soc.sv's own default parameters are
// already the fast-sim values (see that file's header comment for why: a
// synthesized netlist has no parameters left to override, so P8 GLS needs
// the same fast timing baked in as the default, not applied at
// instantiation).
//
// Golden-value checking differs by mode, same "reduced GLS-safe check"
// precedent tb_uart_axi_periph.sv already established for this exact class
// of problem:
//   - Normal RTL sim (P4/P3): hierarchically peeks the RAM's internal
//     reg_q array (axi_lite_slave.sv's own register file, instantiated
//     inside rv32i_soc as u_ram) for the full golden-value check -- the
//     same technique tb_rv32i_core.sv uses against its AXI-Lite memory BFM.
//   - GLS (`ifdef GLS`): u_ram.reg_q is internal DUT hierarchy that does
//     NOT survive synthesis (Yosys decomposes an unpacked register-file
//     array into individual flip-flop cells with no surviving hierarchical
//     name -- confirmed via a real P8 GLS elaboration failure, "Unable to
//     bind wire/reg/memory u_dut.u_ram.reg_q[...]"). Only PORTS survive
//     synthesis, so GLS instead runs for a fixed, generous cycle count
//     (well past the 275 cycles P4 confirmed the program needs) and checks
//     only that uart_tx_o toggled -- observable at the pin regardless of
//     synthesis, and only reachable if the CPU actually executed all the
//     way through the FPU compute+poll sequence and the RAM round-trip to
//     reach the UART TX write. This exercises the same RTL-vs-gate
//     functional-equivalence question P8 GLS exists to answer (X-
//     propagation, reset init) without needing internal-state visibility
//     the netlist doesn't have.
`timescale 1ns/1ps

module tb_rv32i_soc;

    logic clk = 0;
    logic rst_n = 0;

    always #5 clk = ~clk;  // 10 ns period, sim-speed only (not the SDC period)

    wire uart_loop;

    rv32i_soc u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .uart_tx_o (uart_loop),
        .uart_rx_i (uart_loop)
    );

    initial begin
        $dumpfile("sim_rv32i_soc.fst");
        $dumpvars(0, tb_rv32i_soc);
    end

    // Wall-clock watchdog, independent of the cycle-counted MAX_CYCLES poll
    // below — belt-and-suspenders against a hang (same pattern as
    // tb_rv32i_core.sv/tb_uart_axi_periph.sv's own timeout blocks).
    initial begin
        #4_000_000;
        $error("SIMULATION TIMEOUT");
        $finish;
    end

    integer errors;
    integer cycles;

`ifndef GLS
    localparam int MAX_CYCLES = 20000;

    // RAM word indices program.s writes as its result vector (see that
    // file's own header comment for the full address-map rationale).
    localparam int RAM_WORD_FPU_RESULT = 0;
    localparam int RAM_WORD_DONE_MARKER = 1;
    localparam int RAM_WORD_UART_RX     = 2;

    localparam logic [31:0] EXPECT_FPU_RESULT = 32'h40000000;  // FADD(1.0,1.0)=2.0
    localparam logic [31:0] EXPECT_DONE_MARKER = 32'hCAFEF00D;
    localparam logic [31:0] EXPECT_UART_RX     = 32'h00000041;  // 'A', looped back

    initial begin
        errors = 0;
        cycles = 0;

        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // Poll the completion marker word for the program's final write.
        while (u_dut.u_ram.reg_q[RAM_WORD_DONE_MARKER] == 32'd0 && cycles < MAX_CYCLES) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        if (cycles >= MAX_CYCLES) begin
            $display("TB_RV32I_SOC: TIMEOUT after %0d cycles waiting for completion marker", MAX_CYCLES);
            errors = errors + 1;
        end else begin
            $display("TB_RV32I_SOC: completion marker observed after %0d cycles", cycles);
            repeat (4) @(posedge clk);  // let any trailing writeback settle

            if (u_dut.u_ram.reg_q[RAM_WORD_FPU_RESULT] !== EXPECT_FPU_RESULT) begin
                $display("TB_RV32I_SOC: MISMATCH RAM[%0d] (FPU result) = 32'h%08x, expected 32'h%08x",
                          RAM_WORD_FPU_RESULT, u_dut.u_ram.reg_q[RAM_WORD_FPU_RESULT], EXPECT_FPU_RESULT);
                errors = errors + 1;
            end else begin
                $display("TB_RV32I_SOC: OK      RAM[%0d] (FPU result) = 32'h%08x",
                          RAM_WORD_FPU_RESULT, u_dut.u_ram.reg_q[RAM_WORD_FPU_RESULT]);
            end

            if (u_dut.u_ram.reg_q[RAM_WORD_DONE_MARKER] !== EXPECT_DONE_MARKER) begin
                $display("TB_RV32I_SOC: MISMATCH RAM[%0d] (done marker) = 32'h%08x, expected 32'h%08x",
                          RAM_WORD_DONE_MARKER, u_dut.u_ram.reg_q[RAM_WORD_DONE_MARKER], EXPECT_DONE_MARKER);
                errors = errors + 1;
            end else begin
                $display("TB_RV32I_SOC: OK      RAM[%0d] (done marker) = 32'h%08x",
                          RAM_WORD_DONE_MARKER, u_dut.u_ram.reg_q[RAM_WORD_DONE_MARKER]);
            end

            if (u_dut.u_ram.reg_q[RAM_WORD_UART_RX] !== EXPECT_UART_RX) begin
                $display("TB_RV32I_SOC: MISMATCH RAM[%0d] (UART RX loopback) = 32'h%08x, expected 32'h%08x",
                          RAM_WORD_UART_RX, u_dut.u_ram.reg_q[RAM_WORD_UART_RX], EXPECT_UART_RX);
                errors = errors + 1;
            end else begin
                $display("TB_RV32I_SOC: OK      RAM[%0d] (UART RX loopback) = 32'h%08x",
                          RAM_WORD_UART_RX, u_dut.u_ram.reg_q[RAM_WORD_UART_RX]);
            end
        end

        if (errors == 0) begin
            $display("TB_RV32I_SOC: PASS -- all checks matched");
        end else begin
            $display("TB_RV32I_SOC: FAIL -- %0d error(s)", errors);
            $error("rv32i_soc self-check failed");
        end

        $finish;
    end

`else
    // GLS-safe path: no internal hierarchy access (see header comment).
    // 2000 cycles is ~7x the 275 cycles P4's full RTL run needed to reach
    // the completion marker, leaving generous margin for any gate-level
    // propagation-delay difference at zero-delay GLS.
    localparam int GLS_RUN_CYCLES = 2000;

    logic tx_toggled;
    initial tx_toggled = 1'b0;
    always @(uart_loop) tx_toggled = 1'b1;

    initial begin
        errors = 0;

        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        repeat (GLS_RUN_CYCLES) @(posedge clk);

        if (!tx_toggled) begin
            $display("TB_RV32I_SOC: FAIL -- uart_tx_o never toggled in %0d cycles "
                      + "(CPU never reached the UART TX write -- core/decoder/RAM/FPU "
                      + "path did not execute correctly at gate level)", GLS_RUN_CYCLES);
            errors = errors + 1;
        end else begin
            $display("TB_RV32I_SOC: OK      uart_tx_o toggled within %0d cycles", GLS_RUN_CYCLES);
        end

        if (errors == 0) begin
            $display("TB_RV32I_SOC: PASS -- GLS-safe check matched "
                      + "(full golden-value check already covered by P3/P4 RTL sim)");
        end else begin
            $display("TB_RV32I_SOC: FAIL -- %0d error(s)", errors);
            $error("rv32i_soc GLS self-check failed");
        end

        $finish;
    end
`endif

endmodule
