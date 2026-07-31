# fpu_top — Design Choices
### Why the RTL is structured the way it is

---

## 1. What This IP Does

`fpu_top` is a 32-bit IEEE-754 Floating-Point Unit for a RISC-V integer core.
It handles every floating-point instruction in the RV32F extension:
add, subtract, multiply, fused-multiply-add, divide, square root, compare,
classify, sign-inject, and integer↔float conversions.

```
         ┌─────────────────────────────────────────────────────────┐
         │                     fpu_top                             │
         │                                                         │
  valid_i│ ──►  DISPATCH ──┬─► fpu_fma      ────────────────────► │ result_o
  op_i   │                 ├─► fpu_divsqrt  ──►  fpu_round ──────► │ fflags_o
  rm_i   │                 ├─► fpu_cvt      ──►  fpu_flags ──────► │ valid_o
  src_a_i│                 └─► fpu_noncomp  ──►  fpu_result_mux ──► │ busy_o
  src_b_i│                                                         │
  src_c_i│  ◄── ready_o  (asserted when NOT busy)                 │
         └─────────────────────────────────────────────────────────┘
```

---

## 2. The 10 RTL Modules and Their Roles

```
fpu_top.sv              ← top-level dispatcher + handshake logic
│
├── fpu_fma.sv          ← FADD / FSUB / FMUL / FMADD / FMSUB / FNMADD / FNMSUB
│     (652 lines, 4 pipeline stages, pipelined, ~200 FFs)
│
├── fpu_divsqrt.sv      ← FDIV / FSQRT (sequential, 30-iteration Newton-Raphson)
│     (301 lines, ~200 FFs, drives busy_o=1 while iterating)
│
├── fpu_cvt.sv          ← FCVT.W.S / FCVT.WU.S / FCVT.S.W / FCVT.S.WU
│     (297 lines, 2-stage pipeline, sign/magnitude unpack → repack)
│
├── fpu_noncomp.sv      ← FCLASS / FSGNJ / FMIN / FMAX / FEQ / FLT / FLE / FMV
│     (503 lines, purely combinational in most paths)
│
├── fpu_round.sv        ← IEEE-754 rounding (RNE/RTZ/RDN/RUP/RMM), COMB
│     (257 lines, shared by fma/cvt/divsqrt, 0 FFs)
│
├── fpu_flags.sv        ← IEEE exception flags (NV/DZ/OF/UF/NX), COMB
│     (46 lines, pure logic tree, 0 FFs)
│
├── fpu_result_mux.sv   ← Select winning result from 4 functional units, COMB
│     (90 lines, op-decode gated mux, 0 FFs)
│
├── fpu_operand_iso.sv  ← Isolation cells for UPF power domains, COMB
│     (58 lines, simple AND-gate isolation, 0 FFs)
│
└── fpu_clk_gate_ctrl.sv← Clock-gate enable logic for each sub-unit, COMB
      (50 lines, one enable per unit, 0 FFs)
```

The split into 5 purely-combinational leaf modules and 5 pipelined/sequential
modules is the most important structural decision and directly drove how
verification worked (see `buildchoices.md`).

---

## 3. Opcode Routing

`op_i[5:4]` selects the functional unit. Bits `[3:0]` carry the instruction
sub-type (e.g., which rounding mode, add vs. subtract).

```
op_i[5:4]  Unit         Instructions
──────────────────────────────────────────────────────────────
  2'b00    fpu_fma      FADD FSUB FMUL FMADD FMSUB FNMADD FNMSUB
  2'b01    fpu_divsqrt  FDIV FSQRT
  2'b10    fpu_cvt      FCVT.W.S  FCVT.WU.S  FCVT.S.W  FCVT.S.WU
                        FMV.X.W   FMV.W.X
  2'b11    fpu_noncomp  FCLASS FSGNJ FSGNJN FSGNJX FEQ FLT FLE
                        FMIN FMAX
```

---

## 4. Valid/Ready Handshake

The FPU uses a two-sided handshake: upstream (from the integer core) and
downstream (to the register file).

```
Upstream handshake:

  CORE              FPU
   │                 │
   │──── valid_i ───►│
   │◄─── ready_o ────│   ready_o = ~busy_o
   │                 │   Transfer accepted when: valid_i & ready_o
   │                 │
   │   [FDIV/FSQRT running: busy_o=1, ready_o=0 — core must stall]
   │   [FMA/CVT/NONCOMP: single-cycle, ready_o stays 1]
```

`busy_o` is only raised by `fpu_divsqrt` during iterative divide/sqrt.
All other instructions retire in 1–4 cycles (FMA pipeline).

---

## 5. NaN-Boxing (RISC-V FP32 in FP64)

When `FLEN=64` and `NAN_BOX_CHECK=1`, the FPU checks that FP32 operands
passed in 64-bit registers have all upper 32 bits set to 1 (RISC-V
canonical NaN-box). If not, the operand is replaced with the canonical NaN
`0x7FC00001` before dispatch. This is required by the RISC-V privilege spec
for correct emulation of mixed FP32/FP64 programs.

For this portfolio target (`FLEN=32`), the generate block compiles to a
simple wire assignment — zero overhead.

---

## 6. Flush-to-Zero (FTZ)

When `FTZ=1`, subnormal inputs (exponent field = 0, mantissa ≠ 0) are
flushed to ±0 before entering any functional unit. This trades IEEE-754
accuracy for area/timing in embedded applications that don't need gradual
underflow. Controlled by a top-level parameter so synthesis can optionally
constant-fold the mux tree out.

---

## 7. Rounding: Why One Shared Module

IEEE-754 defines 5 rounding modes. Rather than duplicating the rounding
logic in FMA, CVT, and divsqrt, a single `fpu_round.sv` module accepts:
- the unrounded mantissa + guard/round/sticky bits
- the rounding mode from `rm_i`
- a sign bit

And produces the correctly-rounded IEEE-754 result and the inexact flag.

This means every functional unit produces an extended-precision intermediate
and hands off to `fpu_round` for the final IEEE correction. The module is
purely combinational — no FFs — which is both correct (rounding is
stateless per-instruction) and critical for formal verification (see
`buildchoices.md`).

---

## 8. Clock Gating Architecture

Rather than having each sub-unit manage its own clock enable, a separate
`fpu_clk_gate_ctrl.sv` generates the per-unit enable signal:

```
  op_i[5:4] ──► fpu_clk_gate_ctrl ──► clk_en_fma
                                   ──► clk_en_div
                                   ──► clk_en_cvt
                                   ──► clk_en_noncomp
```

These enables feed ICG (Integrated Clock Gate) cells inserted by synthesis.
Power savings: idle units are dark. This is a standard RTL clock-gating
technique that avoids fine-grained `if (en)` disable guards in every
sequential always block.

---

## 9. UPF Power Domain

A single `PD_TOP` power domain wraps the entire FPU under UPF intent:
```
fpu_top.upf  →  create_power_domain PD_TOP -elements {fpu_top}
             →  isolation cells on all domain-crossing outputs
             →  fpu_operand_iso.sv implements the actual isolation logic
```

`fpu_operand_iso.sv` is purely combinational: it ANDs each output with an
isolation enable signal. When the domain is powered down, outputs are forced
to 0 (safe value for a floating-point result bus).

---

## 10. Key Numbers

| Metric                  | Value                              |
|-------------------------|------------------------------------|
| Total RTL lines         | 2,583                              |
| Synthesized cells       | 1,004 (sky130, ceiling: 1,200)     |
| Sequential FFs          | ~767                               |
| Combinational modules   | 5                                  |
| Sequential modules      | 5                                  |
| FMA pipeline stages     | 6 (PIPE_FMA=6, r2b EX3-split)      |
| Target frequency (TT)   | 80 MHz (12.5 ns period)            |
| Worst slack (TT 1.80V)  | +0.131 ns  MET                     |
| Worst slack (FF 1.76V)  | +2.861 ns  MET (22.9% margin)      |
| Worst slack (SS 1.28V)  | −84.202 ns (advisory extreme)      |
| Line coverage (P5)      | 95% (686/716 coverable lines)      |
| Toggle coverage (P5)    | 76.8%                              |
| Expr coverage (P5)      | 79.7%                              |
| GLS status              | PASS (sky130 zero-delay Icarus)    |
