// =============================================================================
// fpu_lzd.sv  —  Leading Zero Detector (Priority Encoder)
// =============================================================================
//
// ── WHAT IS THIS? ────────────────────────────────────────────────────────────
//   A "Leading Zero Detector" (LZD) counts how many zero bits appear at the
//   FRONT (most-significant side) of a binary number before the first '1'.
//
//   Example with WIDTH=8:
//     Input:  0 0 0 1 0 1 1 0     ← binary
//             7 6 5 4 3 2 1 0     ← bit positions
//     Output: 3  (bits 7,6,5 are zero; first '1' is at bit 4)
//
// ── WHY DO WE NEED THIS IN AN FPU? ──────────────────────────────────────────
//   IEEE 754 stores numbers in NORMALIZED form: 1.xxxxx × 2^exp
//   The leading "1." is implied (the "hidden bit") and NOT stored.
//
//   After floating-point addition, the result might start with leading zeros:
//     Example: 1.0 - 0.99609375 = 0.00390625
//     In binary: 0.000000100000...
//
//   Before storing this result as a normalized float, we must SHIFT LEFT
//   until the number looks like 1.xxxxx again:
//     0.000000100000... → shift left 7 → 1.00000...
//     New exponent = old exponent − 7
//
//   The LZD tells us HOW MANY positions to shift (7 in this example).
//
//   This is called "normalization" and it's the hardest part of FP addition.
//
// ── WHY IS IT CALLED A "PRIORITY ENCODER"? ───────────────────────────────────
//   It encodes the POSITION of the highest-priority (most-significant) 1-bit.
//   The "priority" means higher bit positions win over lower ones.
//
// ── IMPLEMENTATION ───────────────────────────────────────────────────────────
//   The `for` loop in synthesis does NOT create a sequential counter.
//   It UNROLLS into a priority-encoder tree:
//
//     if   (bit[N-1]) → answer is 0
//     elif (bit[N-2]) → answer is 1
//     elif (bit[N-3]) → answer is 2
//     ...
//
//   The synthesis tool maps this to O(log₂N) gate levels, not O(N).
//   For WIDTH=32 → 5 levels of logic.
//   For WIDTH=64 → 6 levels of logic.
//
// ── SPECIAL CASE ─────────────────────────────────────────────────────────────
//   If the input is ALL ZEROS, there is no leading '1'.
//   In that case:  lzd_o = WIDTH  and  all_zero_o = 1.
//   The caller checks all_zero_o to handle this — it means "the result is 0.0".
//
// =============================================================================

module fpu_lzd #(
    parameter int WIDTH = 32   // number of bits to scan
) (
    input  logic [WIDTH-1:0]      data_i,      // the number to inspect
    output logic [$clog2(WIDTH):0] lzd_o,      // count of leading zeros (0 to WIDTH)
    output logic                   all_zero_o   // 1 if data_i is entirely zero
);

    // =========================================================================
    // Leading-zero count via a priority scan from MSB to LSB.
    //
    // The loop starts at bit [WIDTH-1] (the MSB) and counts down.
    // Each iteration of "if (data_i[i]) then answer = (WIDTH-1-i)" OVERRIDES
    // the previous answer — so the LOWEST index (smallest leading-zero count)
    // wins. This is how a priority encoder behaves.
    //
    // lzd_o defaults to WIDTH (all-zeros case) and gets overwritten as soon
    // as any '1' is found.
    // =========================================================================

    always_comb begin
        lzd_o = WIDTH[$clog2(WIDTH):0];   // default: no '1' found → WIDTH zeros

        // Scan from MSB (high priority) down to LSB (low priority)
        for (int i = WIDTH-1; i >= 0; i--) begin
            if (data_i[i]) begin
                // Bit i is set → there are (WIDTH-1-i) leading zeros
                lzd_o = ($clog2(WIDTH)+1)'(WIDTH - 1 - i);
            end
        end
    end

    // If the entire input is zero, flag it separately
    assign all_zero_o = (data_i == '0);

    // =========================================================================
    // Formal verification properties
    // =========================================================================
`ifdef FORMAL
    always_comb begin
        // LZD must be within [0, WIDTH]
        assert(lzd_o <= WIDTH[$clog2(WIDTH):0]);

        // If top bit is set, LZD must be 0
        if (data_i[WIDTH-1])
            assert(lzd_o == '0);

        // If not all-zero, the bit AT position (WIDTH-1-lzd_o) must be 1
        if (!all_zero_o)
            assert(data_i[WIDTH-1-lzd_o]);

        // If all-zero, lzd_o must equal WIDTH
        if (all_zero_o)
            assert(lzd_o == WIDTH[$clog2(WIDTH):0]);

        // Corner case covers
        cover(lzd_o == '0);              // MSB is set
        cover(lzd_o == WIDTH-1);         // only LSB is set
        cover(all_zero_o);               // all zeros
    end
`endif

endmodule
