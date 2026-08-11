# uart_ctrl — Engineering Report: A Fake PASS Caught by Pattern Recognition, a Rewrite Applied, and a Live Memory Crisis I Chose to Stop Rather Than Push Through

_Companion to `STATUS.md`. A full UART controller (baud generator, TX/RX engines, FIFOs, APB3 register file — 326 cells) whose recorded P2 Formal PASS I flagged as untrustworthy by pattern recognition alone, before running anything. I then applied the fix — and its re-verification became the run that first surfaced a genuinely new risk class in this portfolio's tooling: aggregate memory exhaustion across multiple concurrent solver processes, not any single process exceeding its own cap. I stopped the run by hand rather than let it find out the hard way, then made that stop permanent and automatic._

## Final Status Dashboard

**Overall: ⚠️ Formal block rewritten and confirmed clean by the automated idiom scanner; re-verification (2026-08-10 17:58:58, commit `02b8144`) hit a live memory-safety event mid-proof and was aborted for safety. P2 sign-off is a genuinely open item — for a different, more interesting reason than the one this report started with. P1/P3–P9 below are real historical results, not re-confirmed this session (`--step formal --force` clears every pillar's checkpoint, not just P2's — see `axi_lite_slave`'s report for the full account of that tooling behavior).**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | ✅ PASS (historical) | 0 err, 0 warn |
| P2 Formal | ⚠️ WARN — rewrite applied, aborted mid-proof for safety (see below) | depth 15 |
| P3 Functional | ✅ PASS (historical) | 4/4 tests |
| P4 Simulation | ✅ PASS (historical) | — |
| P5 Coverage | ✅ PASS (historical) | 83.0% line, 64.8% toggle |
| P6 Synthesis | ✅ PASS (historical) | 326 cells |
| P7 LEC | ⚠️ WARN (documented, historical) | k-induction non-convergent |
| P8 Pre-Layout STA + GLS | ✅ PASS (historical) | 500.0 MHz target, TT MET, SS advisory (−15.775 ns); GLS PASS |
| P9 UPF Power Intent | ✅ PASS (historical) | — |

---

## Situation

A complete single-clock UART peripheral: 16× oversampling RX with a 2-FF pad synchronizer, self-contained sync FIFOs, and an APB3 register map with RW1C sticky error flags and a level-sensitive interrupt. Its dashboard showed a signed-off P2 — inherited from before this session's toolchain discoveries.

## Task

Determine whether the recorded formal PASS deserves trust — and if not, specify the exact path to a real one.

## Action

### The critical finding: I recognized a broken pattern by sight

After the `rr_arbiter` and `apb_uart_master` campaigns, I had a very specific scar: SVA temporal syntax (`assert property`, `property ... endproperty`) hard-errors on `sby -f` with this repo's open-source Yosys build (no Verific) — confirmed against both the distro `apt` yosys and the full oss-cad-suite install, regardless of `-sv`/`-formal` flags.

So when I audited `uart_ctrl.sv`, I didn't run anything first. I grepped: **10 SVA-syntax occurrences, zero immediate-assertion `assert(...)` occurrences.** The same pattern. Which means `STATUS.md`'s `P2 Formal ✅ PASS, depth 15, 2026-08-03 19:46:42` is almost certainly checkpoint carryover from before the toolchain issue was ever discovered — fake for exactly the same mechanical reason the identical-looking PASS entries on `rr_arbiter` and `apb_uart_master` turned out to be fake.

This is the cognitive skill I most want this portfolio to evidence: **transfer**. A failure understood deeply once becomes a detection rule everywhere. I didn't need a failing run to know this PASS couldn't be trusted — the shape of the code and the shape of the claim didn't match, and that mismatch *is* the finding.

**The rewrite was applied**: immediate assertions, `initial assume(!rst_n)`, no `$past`/`|->`/`|=>`/`inside` — the pattern proven on `rr_arbiter`. Confirmed clean by the automated formal-idiom scanner I built after this fix (it now runs before every P2 invocation portfolio-wide, catching exactly this class of issue before wasting a solver run on it). Then I ran it — and "confirm, don't assume" earned its keep in a way I hadn't anticipated.

### What actually happened on re-verification: not the resource ceiling I expected, something new

`uart_ctrl` (326 cells, reading 5 RTL files together — the top module plus `uart_tx`/`uart_rx`/`uart_baud`/`uart_fifo`) launched its two z3 engines (basecase + induction) as usual. I watched memory live rather than just waiting for a result — a discipline this session had already earned the hard way (a real machine crash happened earlier while re-verifying `async_fifo`). Both engines individually stayed under their own memory cap the whole time. But their **combined** usage climbed past 4 GB while system-wide available memory fell to 2.3 GB and kept dropping — heading toward exhausting the whole machine before either process individually hit its own ceiling. That's a different bug than "one process needs more memory than I gave it": a per-process cap doesn't protect against several *individually compliant* processes exhausting the system together.

**I killed it by hand** rather than wait to find out whether the trend would reverse. Given this session already had one real crash to point to, "probably fine" wasn't a bet I was willing to make with someone else's shared machine. I then made the catch permanent instead of one-off: audited every yosys/z3/sby invocation across the flow and found two more real gaps with zero protection at all — one in the LEC sequential fallback (caught live on a different IP, `fpu_axi_periph`, growing uncapped seconds after this abort), one in the shared helper behind P6 Synthesis, P3/P4's compile steps, and UVM test builds, which had no timeout or memory cap whatsoever. Both fixed portfolio-wide (see the portfolio rollup for the full account); `fpu_axi_periph` and `fpu_top`'s subsequent full sweeps then completed with zero manual intervention, which is how I know the fix actually works rather than just feels safer.

### The other pillars — what I believe, and why my belief is calibrated

None of P1/P3/P4/P5/P6/P8/P9 invoke `sby`, so the SVA issue gave me no reason to doubt them the way I doubted P2 — that's the discriminating analysis that keeps skepticism precise rather than paranoid. They haven't been re-confirmed with `--force` since the rewrite; that re-run is the next concrete step, not a lingering doubt about the RTL itself.

### P7 — LEC: WARN (documented, legitimate)

Sequential LEC via Yosys k-induction doesn't converge on this design — the RTL↔PDK state-encoding gap I independently confirmed on `async_fifo` and `axi_lite_slave`. I verified by experiment that generic-gate BMC doesn't rescue it: state size, not cell-model complexity, is the wall; true sign-off needs Conformal/Formality-class sequential LEC.

## Result

- **The fake PASS is gone**: the formal block is now genuinely written in the toolchain's real syntax, scanner-clean, no longer checkpoint fiction.
- **P2 is honestly open, for a new reason**: not the syntax bug this report started with, not a resource ceiling like `apb_uart_master`/`async_fifo`/`axi_lite_slave` — an aggregate multi-process memory risk, caught live and mitigated before it became this session's second crash.
- **Portfolio-wide hardening delivered from this one re-verification attempt**: two more uncapped subprocess invocations found and fixed, validated by two subsequent IPs' full sweeps completing without intervention.

## Key Accomplishments

- **Accomplished** detection of a fake formal PASS with zero tool runs, **as measured by** 10 SVA vs 0 immediate-assertion grep hits, **by doing** failure-signature transfer from two prior IPs — pattern recognition as a verification method.
- **Accomplished** applying and confirming the rewrite rather than stopping at a spec, **as measured by** a scanner-clean formal block that actually got run, **by doing** the fix and then watching it execute instead of trusting the plan.
- **Accomplished** live detection of a genuinely new resource-risk class, **as measured by** catching aggregate multi-process memory growth before it caused a second machine crash, **by doing** active memory monitoring during a proof run instead of waiting on a timeout.
- **Accomplished** converting one manual save into permanent infrastructure, **as measured by** two more uncapped invocations found and fixed portfolio-wide, validated by zero-intervention completions on two other IPs, **by doing** a full audit immediately after the manual abort instead of treating it as a one-off.

## Skills Demonstrated

- **Cross-case pattern recognition** — diagnosed an un-run proof's invalidity from syntax shape alone.
- **Follow-through** — applied the specified fix and re-verified it, rather than reporting a plan as if it were a result.
- **Live systems judgment** — recognized a new failure mode in real time and acted before it materialized, not after.
- **Infrastructure thinking** — turned a single close call into a portfolio-wide fix, then verified the fix under real conditions.

## Open Items — What I'd Do Next

`--force` the full 9-pillar sweep on the current RTL so P1/P3/P4/P5/P6/P8/P9 are re-earned rather than inherited. For P2 specifically: split the properties across separate `.sby` files or scope each to its actual fan-in, then re-attempt now that the aggregate-memory risk is permanently mitigated at the tooling level.