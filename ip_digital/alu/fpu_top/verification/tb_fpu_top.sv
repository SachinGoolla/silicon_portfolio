// =============================================================================
// tb_fpu_top.sv  —  Verilator / Icarus Testbench Wrapper
// =============================================================================
//
// This is a THIN SHELL around the DUT (fpu_top).
// Its only jobs are:
//   1. Generate a clock
//   2. Set up waveform dumping (VCD file) so you can view signals in GTKWave
//   3. Provide a timeout so the simulation doesn't hang forever
//
// The ACTUAL test vectors and checking are done in test_fpu_top.py (cocotb).
// Cocotb drives all the input signals and reads all the output signals
// through its Python↔SystemVerilog interface.
//
// You run this via:
//   pillar --top fpu_top --ip-path ip_digital/alu/fpu_top --step functional
//
// =============================================================================

module tb_fpu_top;

    // ── Parameters matching the DUT ───────────────────────────────────────
    localparam int FLEN = 32;
    localparam int XLEN = 32;

    // ── DUT signal declarations ───────────────────────────────────────────
    logic              clk;
    logic              rst_n;

    logic              valid_i;
    logic              ready_o;
    logic [5:0]        op_i;
    logic [1:0]        fmt_i;
    logic [2:0]        rm_i;
    logic [FLEN-1:0]   src_a_i;
    logic [FLEN-1:0]   src_b_i;
    logic [FLEN-1:0]   src_c_i;
    logic [XLEN-1:0]   int_src_i;
    logic              ready_i;

    logic [FLEN-1:0]   result_o;
    logic [XLEN-1:0]   int_result_o;
    logic              valid_o;
    logic              busy_o;
    logic [4:0]        fflags_o;

    // ── Instantiate the DUT ───────────────────────────────────────────────
    // GLS: synthesized netlist has parameters compiled away — no param override.
`ifdef GLS
    fpu_top dut (
`else
    fpu_top #(
        .FLEN (FLEN),
        .XLEN (XLEN)
    ) dut (
`endif
        .clk          (clk),
        .rst_n        (rst_n),
        .valid_i      (valid_i),
        .ready_o      (ready_o),
        .op_i         (op_i),
        .fmt_i        (fmt_i),
        .rm_i         (rm_i),
        .src_a_i      (src_a_i),
        .src_b_i      (src_b_i),
        .src_c_i      (src_c_i),
        .int_src_i    (int_src_i),
        .ready_i      (ready_i),
        .result_o     (result_o),
        .int_result_o (int_result_o),
        .valid_o      (valid_o),
        .busy_o       (busy_o),
        .fflags_o     (fflags_o)
    );

    // ── Clock: 100 MHz (10 ns period) ─────────────────────────────────────
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // ── VCD waveform dump ─────────────────────────────────────────────────
    // The cocotb/pillar framework passes a VCD path via plusargs.
    // Open the VCD in GTKWave after simulation to see all signal values.
    string vcd_path;
    initial begin
        if ($value$plusargs("vcd=%s", vcd_path))
            $dumpfile(vcd_path);
        else
            $dumpfile("sim.vcd");
        $dumpvars(0, tb_fpu_top);
    end

    // ── Safety timeout ────────────────────────────────────────────────────
    // If cocotb fails to call $finish, this prevents an infinite loop.
    initial begin
        #500_000;
        $display("[TIMEOUT] Simulation exceeded 500us — killing.");
        $finish;
    end

endmodule
