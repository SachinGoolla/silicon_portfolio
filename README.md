# Custom Silicon & Mixed-Signal IP Portfolio

This repository contains a full-stack digital and mixed-signal silicon infrastructure, demonstrating end-to-end IP ownership from analog behavioral modeling to physical design and custom characterization.

## 🏗️ Core Architecture Pillars

### 1. Mixed-Signal DSP Subsystem (Analog to RTL)
* **Sigma-Delta ADC Modulator:** Modeled in SystemVerilog Real Number Modeling (SV-RNM) bridging continuous $s$-domain physics into discrete $z$-domain time-steps.
* **CIC Decimation Filter:** Synthesizable SystemVerilog RTL utilizing Two's Complement overflow arithmetic for a multiplier-less architecture.
* **Clock Domain Crossing (CDC):** Asynchronous FIFO design using Gray code pointers for safe data transfer between the fast oversampling clock and the slow system clock.

### 2. Custom Memory Characterization
* Python and Tcl-based automation engine designed to parse SPICE transient simulations and automatically generate IEEE-standard Liberty (`.lib`) Non-Linear Delay Models (NLDM) for custom SRAM IP.

### 3. Automated Physical Design (RTL-to-GDSII)
* Tcl-driven physical design flow targeting 45nm utilizing OpenROAD.
* Includes logic synthesis, floorplanning, clock tree synthesis (CTS), and Static Timing Analysis (STA) closure.

## 🛠️ Tech Stack
* **Languages:** SystemVerilog (IEEE 1800-2012), Python 3, Tcl, Bash.
* **Verification:** Icarus Verilog, GTKWave, UVM methodologies.
* **Physical Implementation:** Yosys, OpenROAD, KLayout.
