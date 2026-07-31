# Custom Silicon & Mixed-Signal IP Portfolio

Full-stack digital and mixed-signal silicon infrastructure demonstrating end-to-end
IP ownership — from analog behavioral modeling through RTL, formal, simulation,
synthesis, LEC, STA, gate-level simulation, and power intent verification.

---

## Featured IP: IEEE 754 FPU (fpu_top) — All-PASS 9-Pillar Verification

`ip_digital/fpu/fpu_top` — A parameterized RV32F/RVD floating-point unit verified
through a fully automated 9-pillar sign-off flow (`scripts/pillar.py`).

**RTL:** 10 SystemVerilog modules · 2,583 lines · FP32/FP64/FP16 via FLEN parameter  
**Operations:** FADD/FSUB/FMUL/FMADD/FMSUB/FNMADD/FNMSUB · FDIV · FSQRT ·
FCVT (int↔fp) · FCLASS · FSGNJ · FMIN/FMAX · FEQ/FLT/FLE · FMV

| Pillar | Tool | Result |
|--------|------|--------|
| P1 Lint + CDC | Verilator 5.036 | PASS — 0 errors |
| P2 Formal | SymbiYosys / Z3 k-induction | PASS — prove + cover |
| P3 Functional | cocotb 2.0.1 + pyUVM 4.0.1 / Icarus | 24/24 PASS (126 checks) |
| P4 Simulation | Verilator binary + FST | PASS |
| P5 Coverage | verilator_coverage | Line 95% · Toggle 76.8% · Expr 79.7% |
| P6 Synthesis | Yosys 0.33 → sky130 | 1,004 cells |
| P7 LEC | Yosys miniSAT | 5/5 combinational modules PASS |
| P8 STA + GLS | OpenSTA 2.7.0 (3-corner) + Icarus | TT +0.131 ns MET · GLS PASS |
| P9 UPF | Yosys read_upf | PASS (PD_TOP + isolation cells) |

**Notable technical achievements:**
- Timing closure: EX3 pipeline split (r2b register) closed 80 MHz from −0.390 ns → +0.131 ns
- lpflow cell pre-filter: removed 34 power-gating cells from liberty, exposing real SS slack
- pyUVM layer: 4 UVM tests with driver/monitor/scoreboard/coverage components
- Expression coverage: `--coverage-expr` added to P4; v_expr parsing in P5

---

## Portfolio Architecture

### 1. Mixed-Signal DSP Subsystem (Analog to RTL)
* **Sigma-Delta ADC Modulator:** SystemVerilog Real Number Modeling (SV-RNM) bridging
  continuous s-domain physics into discrete z-domain time-steps.
* **CIC Decimation Filter:** Synthesizable RTL using Two's Complement overflow arithmetic
  for a multiplier-less architecture.
* **Clock Domain Crossing (CDC):** Asynchronous FIFO with Gray code pointers for safe
  data transfer between oversampling and system clock domains.

### 2. Custom Memory Characterization
* Python/Tcl automation engine parsing SPICE transient simulations to generate
  IEEE-standard Liberty NLDM (.lib) files for custom SRAM IP.

### 3. Automated Physical Design (RTL-to-GDSII)
* Tcl-driven physical design flow targeting 45nm via OpenROAD.
* Includes logic synthesis, floorplanning, CTS, and STA closure.

---

## Tech Stack
* **Languages:** SystemVerilog (IEEE 1800-2012), Python 3, Tcl, Bash
* **Verification:** Verilator 5.036, Icarus 12.0, cocotb 2.0.1, pyUVM 4.0.1,
  SymbiYosys v0.64, Z3 SMT solver
* **Physical Implementation:** Yosys 0.33, OpenSTA 2.7.0, OpenROAD, KLayout
* **PDK:** sky130 (3-corner STA: FF/TT/SS) via OSS CAD Suite
