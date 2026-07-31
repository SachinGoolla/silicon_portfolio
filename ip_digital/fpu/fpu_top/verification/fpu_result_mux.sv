// =============================================================================
// fpu_result_mux.sv  —  One-Hot Result Arbitration
// =============================================================================
//
// At most one sub-unit produces a valid result in any given clock cycle:
//   • FMA unit: latency 4 cycles (pipelined, accepts new op every cycle)
//   • Div/Sqrt:  latency 14–30 cycles (iterative, busy_o blocks new issue)
//   • Conversion: latency 2 cycles
//   • Non-compute: latency 1 cycle
//
// The decode logic in fpu_top guarantees that only the addressed unit
// receives a valid_i pulse, so two units cannot simultaneously produce
// valid_o.  The priority encoding below (ncomp > fma) is therefore purely
// defensive — it would only matter if there were a decode bug.
//
// EXTENSION HOOK (Phase 4):
//   Add div_valid_i / cvt_valid_i ports with the same pattern used for FMA
//   and ncomp.  The arbitration naturally extends: add an `if (div_valid_i)`
//   block above the ncomp block so that multi-cycle results have priority
//   over any pipelined result that happens to land on the same cycle.
//
// =============================================================================

module fpu_result_mux #(
    parameter int FLEN = 32,
    parameter int XLEN = 32
) (
    // FMA unit result
    input  logic              fma_valid_i,
    input  logic [FLEN-1:0]   fma_result_i,
    input  logic [4:0]        fma_fflags_i,

    // Non-compute unit result
    input  logic              ncomp_valid_i,
    input  logic [FLEN-1:0]   ncomp_result_i,
    input  logic [XLEN-1:0]   ncomp_int_result_i,
    input  logic [4:0]        ncomp_fflags_i,

    // Div/Sqrt unit result (multi-cycle)
    input  logic              div_valid_i,
    input  logic [FLEN-1:0]   div_result_i,
    input  logic [4:0]        div_fflags_i,

    // CVT unit result (1-cycle)
    input  logic              cvt_valid_i,
    input  logic [FLEN-1:0]   cvt_result_i,
    input  logic [XLEN-1:0]   cvt_int_result_i,
    input  logic [4:0]        cvt_fflags_i,

    // Merged output — forwarded directly to fpu_top output ports
    output logic              valid_o,
    output logic [FLEN-1:0]   result_o,
    output logic [XLEN-1:0]   int_result_o,
    output logic [4:0]        fflags_o
);

    always_comb begin
        valid_o      = 1'b0;
        result_o     = '0;
        int_result_o = '0;
        fflags_o     = 5'b0;

        if (fma_valid_i) begin
            valid_o  = 1'b1;
            result_o = fma_result_i;
            fflags_o = fma_fflags_i;
        end

        if (ncomp_valid_i) begin
            valid_o      = 1'b1;
            result_o     = ncomp_result_i;
            int_result_o = ncomp_int_result_i;
            fflags_o     = ncomp_fflags_i;
        end

        if (div_valid_i) begin
            valid_o  = 1'b1;
            result_o = div_result_i;
            fflags_o = div_fflags_i;
        end

        if (cvt_valid_i) begin
            valid_o      = 1'b1;
            result_o     = cvt_result_i;
            int_result_o = cvt_int_result_i;
            fflags_o     = cvt_fflags_i;
        end
    end

endmodule
