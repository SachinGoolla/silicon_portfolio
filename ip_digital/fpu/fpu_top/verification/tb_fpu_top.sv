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
`timescale 1ns/1ps

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


`ifndef COCOTB_SIM
    // ── P4/P5 stimulus (guarded: excluded when COCOTB_SIM is defined) ───────
    // P3 cocotb drives fpu_top directly; this block is for --step sim only.
    // Exercises all four FPU op groups so coverage counters toggle.

    task automatic t_send(
        input [5:0] op, input [31:0] a, b, c, isr,
        input [1:0] fmt, input [2:0] rm
    );
        while (!ready_o) @(posedge clk);
        valid_i = 1; op_i = op; fmt_i = fmt; rm_i = rm;
        src_a_i = a; src_b_i = b; src_c_i = c; int_src_i = isr;
        @(posedge clk); valid_i = 0;
    endtask

    task automatic t_recv();
        automatic int n = 0;
        while (!valid_o && n < 20) begin @(posedge clk); n++; end
        @(posedge clk);  // drain one cycle so next t_send sees correct ready_o
    endtask

    // DIV/SQRT latency: 30 cycles; wait up to 60 to be safe.
    task automatic t_recv_long();
        automatic int n = 0;
        while (!valid_o && n < 60) begin @(posedge clk); n++; end
        @(posedge clk);
    endtask

    initial begin : stim
        rst_n = 0; valid_i = 0; ready_i = 1;
        op_i = 0; fmt_i = 0; rm_i = 0;
        src_a_i = 0; src_b_i = 0; src_c_i = 0; int_src_i = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // ── FMA group (op[5:4]=2'b00): FADD FSUB FMUL FMADD FMSUB FNMADD FNMSUB
        t_send(6'h00, 32'h3F800000, 32'h40000000, 0, 0, 0, 0); t_recv(); // 1.0+2.0
        t_send(6'h01, 32'h40600000, 32'h3FA00000, 0, 0, 0, 0); t_recv(); // 3.5-1.25
        t_send(6'h02, 32'h40000000, 32'h40400000, 0, 0, 0, 0); t_recv(); // 2.0*3.0
        t_send(6'h03, 32'h40000000, 32'h40400000, 32'h3F800000, 0, 0, 0); t_recv(); // 2*3+1
        t_send(6'h04, 32'h40000000, 32'h40400000, 32'h3F800000, 0, 0, 0); t_recv(); // 2*3-1
        t_send(6'h05, 32'h40000000, 32'h40400000, 32'h3F800000, 0, 0, 0); t_recv(); // -(2*3+1)
        t_send(6'h06, 32'h40000000, 32'h40400000, 32'h3F800000, 0, 0, 0); t_recv(); // -(2*3-1)
        // Special values: +Inf, -Inf, NaN, -0, subnormal
        t_send(6'h00, 32'h7F800000, 32'hFF800000, 0, 0, 0, 0); t_recv(); // +Inf+(-Inf)=NaN
        t_send(6'h02, 32'h7F800000, 32'h00000000, 0, 0, 0, 0); t_recv(); // Inf*0=NaN
        t_send(6'h00, 32'h7FC00000, 32'h3F800000, 0, 0, 0, 0); t_recv(); // NaN+1
        t_send(6'h00, 32'h80000000, 32'h3F800000, 0, 0, 0, 0); t_recv(); // -0+1
        t_send(6'h00, 32'h00000001, 32'h00000001, 0, 0, 0, 0); t_recv(); // subnormal+subnormal
        // Rounding modes RTZ RDN RUP RMM on an inexact result
        t_send(6'h02, 32'h3EAAAAAB, 32'h40400000, 0, 0, 0, 3'b001); t_recv();
        t_send(6'h02, 32'h3EAAAAAB, 32'h40400000, 0, 0, 0, 3'b010); t_recv();
        t_send(6'h02, 32'h3EAAAAAB, 32'h40400000, 0, 0, 0, 3'b011); t_recv();
        t_send(6'h02, 32'h3EAAAAAB, 32'h40400000, 0, 0, 0, 3'b100); t_recv();

        // ── CVT group (op[5:4]=2'b10)
        t_send(6'h20, 32'h3FC00000, 0, 0, 0,            0, 0); t_recv(); // FCVT.W.S  1.5→1
        t_send(6'h21, 32'h40000000, 0, 0, 0,            0, 0); t_recv(); // FCVT.WU.S 2.0→2
        t_send(6'h22, 0, 0, 0,          32'hFFFFFFFB,   0, 0); t_recv(); // FCVT.S.W  -5→-5.0
        t_send(6'h23, 0, 0, 0,          32'h00000064,   0, 0); t_recv(); // FCVT.S.WU 100→100.0
        t_send(6'h24, 32'h3F800000, 0, 0, 0,            0, 0); t_recv(); // FMV.X.W
        t_send(6'h25, 0, 0, 0,          32'h40000000,   0, 0); t_recv(); // FMV.W.X
        t_send(6'h20, 32'h7F800000, 0, 0, 0,            0, 0); t_recv(); // CVT +Inf→INT_MAX
        t_send(6'h20, 32'h7FC00000, 0, 0, 0,            0, 0); t_recv(); // CVT NaN→INT_MAX
        t_send(6'h20, 32'hBF800000, 0, 0, 0,            0, 0); t_recv(); // CVT -1.0→-1

        // ── NONCOMP group (op[5:4]=2'b11)
        t_send(6'h30, 32'h3F800000, 0, 0, 0, 0, 0); t_recv(); // FCLASS  +normal
        t_send(6'h30, 32'h80000000, 0, 0, 0, 0, 0); t_recv(); // FCLASS  -0
        t_send(6'h30, 32'h7FC00000, 0, 0, 0, 0, 0); t_recv(); // FCLASS  qNaN
        t_send(6'h30, 32'h7F800000, 0, 0, 0, 0, 0); t_recv(); // FCLASS  +Inf
        t_send(6'h30, 32'h00000001, 0, 0, 0, 0, 0); t_recv(); // FCLASS  subnormal
        t_send(6'h31, 32'h3F800000, 32'hBF800000, 0, 0, 0, 0); t_recv(); // FSGNJ
        t_send(6'h32, 32'h3F800000, 32'hBF800000, 0, 0, 0, 0); t_recv(); // FSGNJN
        t_send(6'h33, 32'h3F800000, 32'hBF800000, 0, 0, 0, 0); t_recv(); // FSGNJX
        t_send(6'h34, 32'h3F800000, 32'h3F800000, 0, 0, 0, 0); t_recv(); // FEQ ==
        t_send(6'h34, 32'h3F800000, 32'h40000000, 0, 0, 0, 0); t_recv(); // FEQ !=
        t_send(6'h34, 32'h7FC00000, 32'h3F800000, 0, 0, 0, 0); t_recv(); // FEQ NaN
        t_send(6'h35, 32'h3F800000, 32'h40000000, 0, 0, 0, 0); t_recv(); // FLT
        t_send(6'h36, 32'h3F800000, 32'h3F800000, 0, 0, 0, 0); t_recv(); // FLE ==
        t_send(6'h37, 32'h3F800000, 32'h40000000, 0, 0, 0, 0); t_recv(); // FMIN
        t_send(6'h38, 32'h3F800000, 32'h40000000, 0, 0, 0, 0); t_recv(); // FMAX
        t_send(6'h37, 32'h80000000, 32'h00000000, 0, 0, 0, 0); t_recv(); // FMIN -0/+0

        // ── Additional FMA: sticky/guard/subnormal coverage ──────────────────
        // Near-unity × near-unity → product=0xFFFFFE_000001, bit[0]=1 → s2_prod_sticky_extra
        t_send(6'h02, 32'h3FFFFFFF, 32'h3FFFFFFF, 0, 0, 0, 0); t_recv();
        // FMADD 2*2+(2^-24): C shifts 26 positions below A*B window → s2_c_sticky
        t_send(6'h03, 32'h40000000, 32'h40000000, 32'h33800000, 0, 0, 0); t_recv();
        // Subnormal product: 2^-63 * 2^-64 = 2^-127 → exercises fpu_round underflow path
        t_send(6'h02, 32'h20000000, 32'h1F800000, 0, 0, 0, 0); t_recv();
        // Inexact FMUL with rm=5 (undefined) → default: round_up=0 branch in fpu_round
        t_send(6'h02, 32'h3EAAAAAB, 32'h40400000, 0, 0, 0, 3'b101); t_recv();

        // ── CVT: missing -Inf/-overflow, FCVT.WU.S saturation, i2f rounding ─
        t_send(6'h20, 32'hFF800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S(-Inf)→INT_MIN
        t_send(6'h20, 32'hCF000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S(-2^31) exact
        t_send(6'h20, 32'hCF800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S(-2^32)→saturate
        t_send(6'h21, 32'h7F800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.WU.S(+Inf)→UINT_MAX
        t_send(6'h21, 32'hBF800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.WU.S(-1.0)→0
        // Large integer (2^25-1=33554431) has MSB at bit24 > 23 → guard bit set
        t_send(6'h22, 0, 0, 0, 32'h01FFFFFF, 0, 3'b001); t_recv(); // FCVT.S.W RTZ
        t_send(6'h22, 0, 0, 0, 32'h01FFFFFF, 0, 3'b100); t_recv(); // FCVT.S.W RMM

        // ── NONCOMP: sNaN FCLASS, both-negative compare, NaN min/max ─────────
        t_send(6'h30, 32'h7F800001, 0, 0, 0, 0, 0); t_recv(); // FCLASS(sNaN)→bit8
        t_send(6'h35, 32'hC0000000, 32'hBF800000, 0, 0, 0, 0); t_recv(); // FLT(-2,-1) both neg
        t_send(6'h37, 32'h7FC00000, 32'h7FC00000, 0, 0, 0, 0); t_recv(); // FMIN(NaN,NaN)→canonical
        t_send(6'h38, 32'h7FC00000, 32'h7FC00000, 0, 0, 0, 0); t_recv(); // FMAX(NaN,NaN)→canonical
        t_send(6'h37, 32'h3F800000, 32'h7FC00000, 0, 0, 0, 0); t_recv(); // FMIN(1.0,NaN)→1.0
        t_send(6'h38, 32'h3F800000, 32'h7FC00000, 0, 0, 0, 0); t_recv(); // FMAX(1.0,NaN)→1.0

        // ── CVT: large integers → FP to toggle i2f_mag[25:31] ──────────────────
        // Bit N of i2f_mag is set when |int_src| ≥ 2^N.  Previous vectors only
        // went up to 2^25-1 (0x01FFFFFF); add powers of 2 for bits 25-31.
        t_send(6'h22, 0, 0, 0, 32'h00000001, 0, 0); t_recv(); // FCVT.S.W   1 → i2f_msb[0]
        t_send(6'h22, 0, 0, 0, 32'h02000000, 0, 0); t_recv(); // FCVT.S.W   2^25 → i2f_mag[25]
        t_send(6'h22, 0, 0, 0, 32'h04000000, 0, 0); t_recv(); // FCVT.S.W   2^26 → i2f_mag[26]
        t_send(6'h22, 0, 0, 0, 32'h10000000, 0, 0); t_recv(); // FCVT.S.W   2^28 → i2f_mag[28]
        t_send(6'h22, 0, 0, 0, 32'h40000000, 0, 0); t_recv(); // FCVT.S.W   2^30 → i2f_mag[30]
        t_send(6'h22, 0, 0, 0, 32'h7FFFFFFF, 0, 0); t_recv(); // FCVT.S.W   INT_MAX → i2f_mag[30:0]
        t_send(6'h23, 0, 0, 0, 32'h80000000, 0, 0); t_recv(); // FCVT.S.WU  2^31  → i2f_mag[31]
        t_send(6'h23, 0, 0, 0, 32'hFFFFFFFF, 0, 0); t_recv(); // FCVT.S.WU  UINT_MAX → i2f_mag[31:0]

        // ── CVT: FP values → INT to toggle int_mag[2:30] ────────────────────
        // int_mag bits are set by powers-of-2 float inputs; cover every missing bit.
        t_send(6'h20, 32'h40800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  4.0    → int_mag[2]
        t_send(6'h20, 32'h41800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  16.0   → int_mag[4]
        t_send(6'h20, 32'h42000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  32.0   → int_mag[5]
        t_send(6'h20, 32'h42800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  64.0   → int_mag[6]
        t_send(6'h20, 32'h43000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  128.0  → int_mag[7]
        t_send(6'h20, 32'h43800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  256.0  → int_mag[8]
        t_send(6'h20, 32'h44000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  512.0  → int_mag[9]
        t_send(6'h20, 32'h44800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  1024.0 → int_mag[10]
        t_send(6'h20, 32'h45000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  2048.0     → int_mag[11]
        t_send(6'h20, 32'h45800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  4096.0     → int_mag[12]
        t_send(6'h20, 32'h46000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  8192.0     → int_mag[13]
        t_send(6'h20, 32'h46800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  16384.0    → int_mag[14]
        t_send(6'h20, 32'h47000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  32768.0    → int_mag[15]
        t_send(6'h20, 32'h47800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  65536.0    → int_mag[16]
        t_send(6'h20, 32'h48000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  131072.0   → int_mag[17]
        t_send(6'h20, 32'h48800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  262144.0   → int_mag[18]
        t_send(6'h20, 32'h49000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  524288.0   → int_mag[19]
        t_send(6'h20, 32'h49800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  1048576.0  → int_mag[20]
        t_send(6'h20, 32'h4A000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  2097152.0  → int_mag[21]
        t_send(6'h20, 32'h4A800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  4194304.0  → int_mag[22]
        t_send(6'h20, 32'h4B000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  8388608.0  → int_mag[23]
        t_send(6'h20, 32'h4B800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  16777216.0 → int_mag[24]
        t_send(6'h20, 32'h4C000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  33554432.0 → int_mag[25]
        t_send(6'h20, 32'h4C800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  67108864.0 → int_mag[26]
        t_send(6'h20, 32'h4D000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  134217728.0→ int_mag[27]
        t_send(6'h20, 32'h4D800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  268435456.0→ int_mag[28]
        t_send(6'h20, 32'h4E000000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  536870912.0→ int_mag[29]
        t_send(6'h20, 32'h4E800000, 0, 0, 0, 0, 0); t_recv(); // FCVT.W.S  1073741824.0→ int_mag[30]

        // ── DIV/SQRT group (op[5:4]=2'b01; latency 30 cycles; use t_recv_long) ──
        t_send(6'h10, 32'h40000000, 32'h3F800000, 0, 0, 0, 0); t_recv_long(); // FDIV 2/1=2
        t_send(6'h10, 32'h3F800000, 32'h40000000, 0, 0, 0, 0); t_recv_long(); // FDIV 1/2=0.5
        t_send(6'h10, 32'h40400000, 32'h40000000, 0, 0, 0, 0); t_recv_long(); // FDIV 3/2=1.5
        t_send(6'h11, 32'h40000000, 0, 0, 0, 0, 0);             t_recv_long(); // FSQRT(2.0)
        t_send(6'h11, 32'h3F800000, 0, 0, 0, 0, 0);             t_recv_long(); // FSQRT(1.0)=1
        t_send(6'h11, 32'h41000000, 0, 0, 0, 0, 0);             t_recv_long(); // FSQRT(8.0)
        // Special cases: div-by-zero, NaN, neg-sqrt, inf, zero
        t_send(6'h10, 32'h3F800000, 32'h00000000, 0, 0, 0, 0); t_recv_long(); // FDIV 1/0=+Inf (DZ)
        t_send(6'h10, 32'h7FC00000, 32'h3F800000, 0, 0, 0, 0); t_recv_long(); // FDIV NaN/1=NaN
        t_send(6'h11, 32'hBF800000, 0, 0, 0, 0, 0);             t_recv_long(); // FSQRT(-1)=NaN (NV)
        t_send(6'h11, 32'h7F800000, 0, 0, 0, 0, 0);             t_recv_long(); // FSQRT(+Inf)=Inf
        t_send(6'h11, 32'h00000000, 0, 0, 0, 0, 0);             t_recv_long(); // FSQRT(+0)=+0
        t_send(6'h10, 32'h7F800000, 32'h7F800000, 0, 0, 0, 0); t_recv_long(); // FDIV Inf/Inf=NaN
        t_send(6'h10, 32'h00000000, 32'h00000000, 0, 0, 0, 0); t_recv_long(); // FDIV 0/0=NaN

        repeat(10) @(posedge clk);
        $display("[P4-STIM] Verilator stimulus complete — all FPU op groups + DIV/SQRT exercised.");
        $finish;
    end
`endif // COCOTB_SIM

endmodule
