// =============================================================================
// fpu_flags.sv  —  IEEE 754 Exception Flag Merge
// =============================================================================
//
// Collects per-cycle IEEE 754 exception flags from all sub-units and
// presents a merged flag word in the same cycle as result_o / valid_o.
//
// WHY A SEPARATE MODULE?
//   In a full four-unit FPU the flags from each unit are OR'd together
//   in the result window.  Isolating this merge makes the flag-path
//   visible to the STA tool and allows it to be timed independently of
//   the data path.  It also gives a single attachment point for a future
//   sticky-accumulation register (for the CPU CSR fflags field).
//
// RISC-V CSR NOTE:
//   The CPU CSR unit accumulates (sticky-ORs) these flags into its
//   fflags register across instructions.  The FPU itself does NOT
//   accumulate — it outputs only the flags for the CURRENT operation.
//   A future fpu_flags_csr.sv wrapper could add sticky accumulation
//   inside the FPU for systems that prefer it.
//
// EXTENSION HOOK (Phase 4):
//   Add div_valid_i / div_fflags_i and cvt_valid_i / cvt_fflags_i ports.
//   Extend the OR merge to include them.
//
// =============================================================================

module fpu_flags (
    input  logic       fma_valid_i,
    input  logic [4:0] fma_fflags_i,
    input  logic       ncomp_valid_i,
    input  logic [4:0] ncomp_fflags_i,
    input  logic       div_valid_i,
    input  logic [4:0] div_fflags_i,
    input  logic       cvt_valid_i,
    input  logic [4:0] cvt_fflags_i,
    output logic [4:0] fflags_o
);
    always_comb begin
        fflags_o = 5'b0;
        if (fma_valid_i)   fflags_o |= fma_fflags_i;
        if (ncomp_valid_i) fflags_o |= ncomp_fflags_i;
        if (div_valid_i)   fflags_o |= div_fflags_i;
        if (cvt_valid_i)   fflags_o |= cvt_fflags_i;
    end
endmodule
