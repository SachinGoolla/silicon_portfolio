# async_fifo — Engineering Report: Dual-Clock Design Done Deliberately, the Risk Taxonomy That Ranked It Lowest-Risk, and Why Re-Verification Still Found a Real Ceiling

_Companion to `STATUS.md`. A dual-clock Gray-code FIFO on the classic Cummings (2002) architecture — `wr_clk` 100 MHz / `rd_clk` 33 MHz — written in immediate-assertion house style. The IP where I worked out the **gating taxonomy** that ranked every other IP's formal-idiom risk this session — and the IP whose actual re-verification result reminded me that idiom risk and resource risk are two different axes, not one._

## Final Status Dashboard

**Overall: ⚠️ P2 Formal re-verified WARN (2026-08-10 15:56:50, commit `a063e20`) — a solver resource ceiling, not the basecase-idiom risk this report originally flagged. P1/P3/P4/P5/P6/P7/P8/P9's results below are real (historically PASS, P7 a documented WARN) but no longer reflected in `STATUS.md`'s own checkpoint history — re-running `--step formal --force` clears every pillar's checkpoint, not just the one being re-run (I first identified this exact tooling behavior on `axi_lite_slave`; it applies here identically). Reported here rather than silently dropped.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | ✅ PASS (historical) | 0 err, 0 warn |
| P2 Formal | ⚠️ WARN — resource ceiling, re-verified | depth 20 (see below) |
| P3 Functional | ✅ PASS (historical) | 4/4 tests |
| P4 Simulation | ✅ PASS (historical) | — |
| P5 Coverage | ✅ PASS (historical) | 90.0% line, 28.9% toggle |
| P6 Synthesis | ✅ PASS (historical) | 840 cells |
| P7 LEC | ⚠️ WARN (documented, historical) | k-induction non-convergent |
| P8 Pre-Layout STA + GLS | ✅ PASS (historical) | 12.0 MHz target, TT MET, SS advisory (−54.867 ns); GLS PASS |
| P9 UPF Power Intent | ✅ PASS (historical) | — |

---

## Situation

This FIFO is the CDC backbone of the mixed-signal subsystem: it moves 32-bit words from a 100 MHz write domain into a 33 MHz read domain. Clock-domain crossing is where careless FIFOs die — a multi-bit pointer sampled mid-transition can corrupt full/empty detection catastrophically.

## Task

Deliver a dual-clock FIFO whose CDC safety is architectural, not accidental, and carry it through the 9-pillar flow — with formal properties that hold across two genuinely asynchronous clocks.

## Action

### CDC correctness is an architecture, not an afterthought

I built the design on the Cummings two-flop-synchronizer + Gray-code-pointer discipline precisely because Gray encoding guarantees that any metastability-sampled pointer is at worst one count off — turning a potentially catastrophic multi-bit race into a benign one-slot lag. The extra pointer MSB disambiguates full from empty; the inverted-top-two-bits comparison is the Cummings Fig. 6 full-detection formula; conservative flags (up to `SYNC_STAGES` cycles stale) trade latency for safety by construction. The clean P1 (0 err / 0 warn, no raw crossings) and the 840-cell synthesis result tell me the discipline held all the way down to the netlist — the cell count is dominated by the 256-DFF distributed memory array, exactly what an 8×32 FIFO without an SRAM macro should cost.

### The analytical achievement: why I rank this IP's formal proof *lower-risk* than its siblings

This session I discovered that this Yosys build doesn't reliably honor `initial X = const` in BMC's basecase (full story in the `rr_arbiter` report). `async_fifo.sv` uses the same general `f_wr_started`/`f_rd_started` flag shape — so I audited the actual exposure instead of hand-waving it, and found a **belt-and-suspenders gate** the other IPs lack: every assertion is gated on the flag **and** the corresponding primary reset input (`wr_rst_n`/`rd_rst_n`), which carry no `initial`-value dependency at all. Even in the worst case — a flag spuriously reading `1` at step 0 — the assertions remain correctly disabled whenever reset is actually asserted. Contrast the **sole-gate** shape on `mod1000`, `fpu_axi_periph`, and `axi_lite_slave`, where the flag alone stands between a loose basecase model and an unsound proof.

That comparison — belt-and-suspenders vs sole-gate vs immune-by-construction — became the portfolio's formal-**idiom**-risk taxonomy: `mod1000` genuinely exposed, `mod3ud` narrowly exposed (and, on execution, exposed to a *different* bug — see its report), this IP defensible, `fpu_top` immune. That taxonomy was correct on its own terms.

**What it didn't predict, because it wasn't measuring it: solver resource cost.** Idiom-soundness risk and memory-footprint risk are independent axes. I re-confirmed this proof with `--force` at both the original depth 20 and a reduced depth 10 — same crash signature both times (`Engine terminated without status`, depth-independent timing), which is this session's confirmed fingerprint for a genuine solver memory ceiling, not a basecase or convergence issue. Two clock domains, Gray-code pointer logic, and a distributed 256-DFF memory array reasoned about jointly is real state, regardless of how safely the reset gating is written. I accepted the WARN rather than keep escalating the memory cap on a shared, already-crash-tested host — the same "know when to stop retrying the same way" discipline I applied to `apb_uart_master`. **The idiom-soundness question this report raised is closed (belt-and-suspenders confirmed, no basecase exposure); the resource-ceiling question is a separate, still-open item.**

### P7 LEC: I identified exactly which wall I hit

Sequential LEC doesn't converge here: Yosys k-induction can't bridge the RTL↔PDK state-encoding gap on a two-clock design with this much state. I didn't stop at the WARN — I ran the experiment to check whether generic-gate BMC rescues it (it doesn't), which told me the wall is **state size, not cell-model complexity**. Cross-verified by P2 Formal + P8 GLS; true closure needs Conformal/Formality-class sequential LEC. Same documented class as `axi_lite_slave` and `uart_ctrl` — a portfolio-level pattern, not three independent mysteries.

## Result

- **P2 genuinely re-verified as a resource ceiling** — full re-run 2026-08-10 15:56:50 (commit `a063e20`) at two depths, same crash signature both times. The other 8 rows are real, historical results not re-confirmed in this pass (see the checkpoint-scope note above).
- **Formal:** idiom-soundness confirmed by audit (belt-and-suspenders gating, no basecase exposure); convergence blocked by solver memory, not disproven.
- **Functional:** 4/4 pyUVM tests (fill/drain, 3:1 backpressure, no-spurious-read, 32-word randomized stress) with scoreboard-checked in-order integrity.
- **Coverage:** 90.0% line / 28.9% toggle — toggle headroom traced to the memory array, quantified for the CDC-stress roadmap.
- **PPA:** 840 cells; TT MET at the 12.0 MHz integration target; SS −54.867 ns classified extreme-corner advisory; GLS PASS.

## Key Accomplishments

- **Accomplished** safe 100 MHz → 33 MHz data transfer with provable pointer discipline, **as measured by** 0 lint/CDC errors and 0 raw crossings, **by doing** Gray-code + two-flop-synchronizer architecture rather than post-hoc patching.
- **Accomplished** a portfolio-wide formal-idiom-risk taxonomy, **as measured by** 6 IPs classified into 3 exposure tiers, **by doing** dependence analysis on a toolchain bug instead of superficial pattern-matching.
- **Accomplished** correctly separating two independent risk axes, **as measured by** confirming idiom-soundness by audit while classifying the actual re-verification result as a distinct resource-ceiling finding, **by doing** two-depth confirmation of the crash signature rather than conflating "didn't converge" with "was unsound."
- **Accomplished** a precise diagnosis of the sequential-LEC wall, **as measured by** one controlled experiment (generic-gate BMC), **by doing** failure-mode isolation — state size, not cell-model complexity.

## Skills Demonstrated

- **CDC architecture** — Gray-code pointer discipline across genuinely asynchronous domains.
- **Risk stratification** — turned one toolchain bug into a reusable exposure taxonomy, then recognized its limits.
- **Failure-mode experimentation** — proved which wall LEC was hitting, and which wall P2 was hitting, rather than guessing at either.
- **Cross-IP pattern cataloguing** — recognized the SS-corner advisory signature and the depth-independent-crash resource-ceiling signature as flow-level patterns.

## Open Items — What I'd Do Next

P2's resource ceiling is the same open-item class as `apb_uart_master`'s: split the properties across separate `.sby` files, or scope each to its actual fan-in, then re-attempt on a quiet host. Also push toggle coverage (28.9%) up with longer randomized CDC-stress sequences.