// Self-checking testbench template with reference model loop.
// Copy to: ip_digital/common_cells/<module>/verification/tb_<module>.sv
// Replace MODULE, CLK_PERIOD_NS, and the reference model body.
//
// Pillar 4 (sim) will FAIL automatically on any $error/$fatal.

`timescale 1ns/1ps

module tb_MODULE;
    // ── DUT signals ─────────────────────────────────────────
    parameter CLK_PERIOD_NS = 10;

    logic        clk, rst_n;
    // TODO: add DUT I/O ports here
    // logic [7:0]  dut_in;
    // logic [7:0]  dut_out;

    // ── DUT instantiation ────────────────────────────────────
    MODULE dut (
        .clk   (clk),
        .rst_n (rst_n)
        // TODO: connect remaining ports
    );

    // ── Clock ────────────────────────────────────────────────
    initial clk = 0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // ── Reference model ──────────────────────────────────────
    // Pure combinational function of inputs — no state, no clocking.
    function automatic logic [7:0] ref_model(input logic [7:0] in_val);
        // TODO: implement expected output calculation
        return in_val;  // placeholder: identity
    endfunction

    // ── Test stimulus + checker ──────────────────────────────
    integer fail_count;
    logic [7:0] expected;

    task automatic check_output(input logic [7:0] in_val, input string test_name);
        expected = ref_model(in_val);
        @(posedge clk); #1;
        // TODO: replace dut_out with actual output port name
        // if (dut_out !== expected)
        //     $error("FAIL [%s]: in=%0h expected=%0h got=%0h at t=%0t",
        //            test_name, in_val, expected, dut_out, $time);
    endtask

    // ── Main test sequence ───────────────────────────────────
    initial begin
        fail_count = 0;
        rst_n      = 0;
        @(posedge clk); @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ── Test 1: Reset state ──────────────────────────────
        // verify DUT output after reset
        // if (dut_out !== 8'h00)
        //     $error("FAIL [reset]: expected 0 got %0h", dut_out);

        // ── Test 2: Normal operation loop ────────────────────
        for (int i = 0; i < 256; i++) begin
            // dut_in = i[7:0];
            check_output(i[7:0], $sformatf("normal_op_%0d", i));
        end

        // ── Test 3: Edge cases ───────────────────────────────
        // dut_in = 8'hFF; check_output(8'hFF, "max_value");
        // dut_in = 8'h00; check_output(8'h00, "min_value");

        // ── Test 4: Reset mid-run ────────────────────────────
        // rst_n = 0; @(posedge clk);
        // rst_n = 1; @(posedge clk);
        // if (dut_out !== 8'h00) $error("FAIL [mid_reset]: expected 0 got %0h", dut_out);

        // ── Done ─────────────────────────────────────────────
        if (fail_count == 0)
            $display("PASS: all checks passed at t=%0t", $time);
        else
            $error("FAIL: %0d check(s) failed", fail_count);

        $finish;
    end

    // ── Timeout watchdog ─────────────────────────────────────
    initial begin
        #(CLK_PERIOD_NS * 10000);
        $fatal(1, "FAIL: simulation timeout — check for infinite loops or missing $finish");
    end

endmodule
