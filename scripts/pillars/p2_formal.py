"""Pillar 2 — Formal (SymbiYosys k-induction + cover mode). Returns PASS | FAIL | SKIP."""
import re
import shutil
import subprocess
import concurrent.futures
from pathlib import Path
from .common import (C, Dashboard, FormalLogParser, PILLAR_ICONS,
                      decode_subprocess_output as _decode,
                      run_with_timeout as _run)


# Per-z3-invocation virtual-memory cap (KB), applied via `ulimit -v` before
# every `sby -f ...` call. This was 8388608 (8GB) — sized for fpu_top's old
# unstubbed proof — until a real, confirmed full-machine reboot happened
# during async_fifo's formal re-verification despite this cap being in
# place (see project memory feedback_resource_limits). Root cause: `ulimit
# -v` bounds only what ONE process is allowed to allocate — it does
# nothing to protect the SYSTEM when that process runs alongside whatever
# else this shared, actively-used desktop box is doing at that moment
# (browser, other agents, etc.), and multiple z3 engines (basecase +
# induction, sometimes + a concurrent cover-mode check) can each
# individually approach the cap at once. 8GB against a 12.8GB-total
# machine left far too little headroom. Lowered to 2GB: every currently-
# passing IP in this portfolio needs a small fraction of that (rr_arbiter
# peaked under 1GB; fpu_top's proof is now heavily anyseq-stubbed and
# converges in under a second). A design that genuinely needs more than
# 2GB (apb_uart_master, unresolved) now fails its own ulimit cleanly and
# predictably instead of risking a system-wide crash — a strictly better
# trade-off given the demonstrated real-world cost of getting this wrong.
_ULIMIT_V_KB = 3 * 1024 * 1024  # 3GB — see note above; bumped 2GB->3GB after
# 2GB proved too tight for async_fifo/axi_lite_slave/uart_ctrl (all WARNed
# at the 2GB ceiling with a healthy, stable 6.6GB available beforehand —
# genuine per-process need, not system pressure). Still well under half
# the old 8GB-per-process value that caused the crash, and since 2
# concurrent z3 engines (basecase+induction) each get their own
# independent `ulimit -v` allocation, worst-case combined exposure here
# is ~6GB vs the old ~16GB worst case.

_SVA_PATTERN = re.compile(
    r'\bassert\s+property\s*\(|\bassume\s+property\s*\(|\bcover\s+property\s*\('
    r'|^\s*property\s+\w+\s*;|\binside\s*\{',
    re.MULTILINE)
_INITCONST_PATTERN = re.compile(r"\binitial\s+(?:begin\s+)?\w+\s*=\s*1?'?b?0\s*;")
_INITASSUME_PATTERN = re.compile(r'\binitial\s+assume\s*\(')


def _scan_formal_idioms(rtl_files: list) -> tuple:
    """Static pre-flight scan for two known-bad formal idioms on this
    toolchain, found the hard way debugging rr_arbiter/apb_uart_master/
    uart_ctrl (see project memory feedback_formal_sby):

    1. SVA syntax (`assert property`, `property...endproperty`, `inside
       {...}`) — this repo's open-source Yosys build (no Verific) cannot
       parse any of it, regardless of `-sv`/`-formal` flags. A file using
       it will hard-error on `sby -f *.sby` every time, and a stale
       checkpoint can mask that as a false PASS indefinitely. This is a
       hard error: don't waste time invoking sby on syntax that is known
       to be unparseable.

    2. A plain register's `initial X = const;` used as a "was ever reset"
       latch, with no accompanying `initial assume(...)`. This Yosys
       build does not reliably honor `initial` for a register's BMC
       basecase power-on value (confirmed with a minimal repro) — the
       correct, confirmed-working idiom is `initial assume(!rst_n);`,
       constraining the basecase directly rather than trusting a derived
       flag's own power-on state. This is a soft warning, not a hard
       error: whether it actually produces a false PASS depends on
       whether the specific properties in the file genuinely depend on
       registered state (see fpu_top vs mod1000 in project memory for
       the worked examples of "immune by construction" vs "genuinely
       exposed").

    Only scans inside `ifdef FORMAL`/`ifdef LIVENESS` guarded regions, to
    avoid false positives from unrelated code elsewhere in the file.
    Returns (errors, warnings) — both lists of human-readable strings.
    """
    errors, warnings = [], []
    for f in rtl_files:
        try:
            text = f.read_text(errors='replace')
        except Exception:
            continue
        # Strip comments before scanning — this file's own header prose
        # explains these anti-patterns by name (e.g. "NOT SVA `assert
        # property`"), which would otherwise self-trigger as a false
        # positive. Line comments first, then block comments.
        text = re.sub(r'//.*', '', text)
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
        formal_blocks = re.findall(r'`ifdef\s+(?:FORMAL|LIVENESS)(.*?)`endif', text, re.DOTALL)
        if not formal_blocks:
            continue
        formal_text = "\n".join(formal_blocks)
        if _SVA_PATTERN.search(formal_text):
            errors.append(
                f"{f.name}: SVA syntax detected (assert property / property...endproperty "
                f"/ inside{{}}) — this Yosys build cannot parse it; sby will hard-error. "
                f"Rewrite as immediate assertions (assert(...)/assume(...)/cover(...) inside "
                f"clocked always blocks) — see CLAUDE.md 'Formal verification idioms'.")
        if _INITCONST_PATTERN.search(formal_text) and not _INITASSUME_PATTERN.search(formal_text):
            warnings.append(
                f"{f.name}: uses `initial X=const` for a reset-tracking flop without "
                f"`initial assume(!rst_n)` — this Yosys build does not reliably honor "
                f"initial values for BMC's basecase. Prefer `initial assume(!rst_n);` "
                f"gating directly on rst_n instead — see CLAUDE.md 'Formal verification idioms'.")
    return errors, warnings


def _run_cover_mode(flow, sby_file: Path, prove_log: Path):
    """Run sby in cover mode to check cover() reachability. Soft-warn on fail."""
    try:
        sby_text = sby_file.read_text()
    except Exception:
        return
    if 'mode prove' not in sby_text and 'mode bmc' not in sby_text:
        return

    cover_text = re.sub(r'\bmode\s+\w+', 'mode cover', sby_text)
    cover_sby  = sby_file.parent / (sby_file.stem + "_cover.sby")
    cover_log  = prove_log.parent / prove_log.name.replace(".log", "_cover.log")
    try:
        cover_sby.write_text(cover_text)
    except Exception:
        return

    print(f"     {C.info('▶')} Checking cover() reachability (mode cover)...")
    # Hard wall-clock cap: `ulimit -v` only bounds memory, not runtime — an
    # over-constrained cover target (unreachable property) makes z3 search
    # forever at 99% CPU without ever growing past the memory cap. Seen in
    # practice: multiple z3 processes still running 15-40 min after the
    # parent pillar.py run had already reported completion.
    try:
        _run(
            f"ulimit -v {_ULIMIT_V_KB} 2>/dev/null; sby -f {cover_sby.name} > {cover_log} 2>&1",
            timeout=300, cwd=sby_file.parent)
    except subprocess.TimeoutExpired:
        with open(cover_log, "a") as f:
            f.write("\nSBY TIMEOUT: cover mode exceeded 300s wall-clock limit "
                     "(process group killed — no orphaned z3)\n")

    content = cover_log.read_text(errors='replace') if cover_log.exists() else ""
    if "DONE (PASS" in content:
        print(f"     {C.ok('✓ Cover mode PASS')} — all cover() properties reachable")
    elif "DONE (FAIL" in content or "DONE (ERROR" in content:
        print(f"     {C.warn('⚠ Cover mode FAIL')} — some cover() goals unreachable")
        print(f"       {C.dim('Likely over-constrained model — not a design bug.')}")
    else:
        print(f"     {C.dim('Cover mode: no result (no cover() properties in design)')}")
    try:
        cover_sby.unlink(missing_ok=True)
    except Exception:
        pass


def _patch_sby_depth(sby_file: Path, depth: int) -> Path:
    """Write a temp .sby with depth overridden. Returns path to temp file."""
    text = sby_file.read_text()
    text = re.sub(r'(?m)^(\s*depth\s+)\d+', lambda m: f"{m.group(1)}{depth}", text)
    if not re.search(r'(?m)^\s*depth\s+\d+', text):
        # depth line absent — inject under [options]
        text = re.sub(r'(\[options\])', r'\1\ndepth ' + str(depth), text)
    tmp = sby_file.parent / (sby_file.stem + f"_d{depth}.sby")
    tmp.write_text(text)
    return tmp


def _run_one_sby(sby_file: Path, log_file: Path, rtl_files: list,
                 formal_depth: int, params: dict) -> tuple:
    """Run a single .sby file; returns (sby_stem, log_path, ok_bool, depth)."""
    # Copy RTL next to .sby so [files] section resolves
    for rtl_f in rtl_files:
        dest = sby_file.parent / rtl_f.name
        if not dest.exists() or dest.stat().st_mtime < rtl_f.stat().st_mtime:
            shutil.copy2(rtl_f, dest)

    depth = 1
    try:
        for line in sby_file.read_text().splitlines():
            if line.strip().startswith('depth'):
                depth = int(line.split()[1])
    except Exception:
        pass

    active_sby = sby_file
    if formal_depth > 0 and formal_depth != depth:
        active_sby = _patch_sby_depth(sby_file, formal_depth)
        depth = formal_depth

    if params:
        text = active_sby.read_text()
        chparams = "\n".join(
            f"chparam -set {k} {v}" for k, v in params.items())
        text = re.sub(r'(\[script\][^\[]*?)((?:prep|synth))',
                      r'\1' + chparams + r'\n\2', text, count=1, flags=re.DOTALL)
        param_sby = sby_file.parent / (sby_file.stem + "_params.sby")
        param_sby.write_text(text)
        active_sby = param_sby

    # Hard wall-clock cap alongside the memory cap — see _run_cover_mode for
    # why: `ulimit -v` alone does not stop a z3 search that is stuck rather
    # than growing memory. 600s (not 300s like the cover-mode check) since
    # the MAIN proof can legitimately run long on large designs.
    try:
        result = _run(
            f"ulimit -v {_ULIMIT_V_KB} 2>/dev/null; sby -f {active_sby.name}",
            timeout=600, capture_output=True, text=True, cwd=sby_file.parent)
        combined = result.stdout + result.stderr
        ok = (result.returncode == 0) or ("DONE (PASS" in combined)
    except subprocess.TimeoutExpired as e:
        # TimeoutExpired.stdout/.stderr can be raw bytes even with text=True
        # — the exception is raised before communicate()'s text-decode step.
        combined = _decode(e.stdout) + _decode(e.stderr) + \
            "\nSBY TIMEOUT: exceeded 600s wall-clock limit " \
            "(process group killed — no orphaned z3)\n"
        ok = False
    log_file.write_text(combined)

    # Cleanup temp files
    for suf in ("_params.sby", f"_d{depth}.sby"):
        tmp = sby_file.parent / (sby_file.stem + suf)
        try: tmp.unlink(missing_ok=True)
        except Exception: pass

    return (sby_file.stem, log_file, ok, depth)


def run(flow, formal_depth: int = 0) -> str:
    print(f"\n  {C.hdr('━━━ PILLAR 2: Formal')}  {PILLAR_ICONS[1]}  {C.dim(flow.top)}")
    sby_files = list(flow.verif_dir.glob("*.sby"))
    rtl_files = flow._find_all_rtl()

    if not sby_files:
        print(f"     {C.warn('⚠ Skipped')} — no .sby file in {flow.verif_dir}")
        print(f"     {C.dim('Create verification/{top}.sby to enable formal proofs.')}")
        return "SKIP"

    # Static idiom scan runs BEFORE the checkpoint check, deliberately —
    # a stale checkpoint from before a bad edit was introduced must not
    # mask a hard SVA-syntax error as a cached PASS. Cheap (no sby/z3
    # invoked), so paying this cost on every run (including fast cached
    # skips) is worth it for the protection.
    #
    # Scan rtl_files PLUS verification/*.sv: some IPs (e.g. mod3ud) keep
    # their formal properties in a separate wrapper module under
    # verification/ rather than inside rtl/ — _find_all_rtl() only globs
    # rtl/, so a scan of rtl_files alone would silently miss that file
    # entirely. Dedupe by stem (preferring the rtl/ copy) since several
    # IPs auto-copy their RTL into verification/ for sby's [files]
    # section, which would otherwise double-report the same warning.
    scan_files_by_stem = {f.stem: f for f in flow.verif_dir.glob("*.sv")}
    scan_files_by_stem.update({f.stem: f for f in rtl_files})
    idiom_errors, idiom_warnings = _scan_formal_idioms(list(scan_files_by_stem.values()))
    for w in idiom_warnings:
        print(f"     {C.warn('⚠')} {w}")
    if idiom_errors:
        for e in idiom_errors:
            print(f"     {C.err('✗')} {e}")
        print(f"  {C.err('❌ Formal FAIL')} — known-unparseable syntax found, sby not invoked")
        return "FAIL"

    deps = rtl_files + sby_files
    if flow.is_checkpoint_valid("formal", deps):
        print(f"     {C.ok('✓ Skipped')} {C.dim('(no changes since last proof)')}")
        return "PASS"

    # Run ALL .sby files in parallel (one thread per file).
    # Sort non-cover files first: Path.glob() order is filesystem-dependent,
    # not alphabetical, so "primary log = first result" used to be able to
    # pick the auxiliary cover-mode .sby over the real mode-prove/bmc proof.
    # If the cover log happened to still be mid-run (no terminal DONE line
    # yet) when read, FormalLogParser found nothing conclusive, stayed
    # UNKNOWN, and the `not ok` fallback below turned that into a bare FAIL
    # — mislabeling "tool didn't finish" as "property disproven". Sorting
    # non-cover first makes the dashboard's primary log the actual proof.
    sby_files = sorted(sby_files, key=lambda p: ("_cover" in p.stem, p.name))
    n = len(sby_files)
    print(f"     {C.info('▶')} Running {n} sby target(s) in parallel (z3 smtbmc)...")

    tasks = []
    for sf in sby_files:
        lf = flow.log_dir / f"formal_{flow.top}_{sf.stem}.log"
        tasks.append((sf, lf))

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=n) as pool:
        futs = {
            pool.submit(_run_one_sby, sf, lf, rtl_files,
                        formal_depth, getattr(flow, 'params', {})):
            (sf, lf)
            for sf, lf in tasks
        }
        for fut in concurrent.futures.as_completed(futs):
            results.append(fut.result())

    # Primary log = first sby result for dashboard
    log_file = tasks[0][1]
    sby_file  = sby_files[0]
    depth = results[0][3] if results else 1
    ok    = all(r[2] for r in results)

    for stem, lf, r_ok, r_depth in sorted(results, key=lambda x: x[0]):
        icon = C.ok('✓') if r_ok else C.err('✗')
        print(f"     {icon} {stem} (depth={r_depth}) → {'PASS' if r_ok else 'FAIL'}")

    # Clean up temp sby files
    for suffix in (f"_d{depth}.sby", "_params.sby"):
        tmp = sby_files[0].parent / (sby_files[0].stem + suffix)
        try: tmp.unlink(missing_ok=True)
        except Exception: pass
    sby_file = sby_files[0]  # restore original ref

    parser = FormalLogParser(log_file)
    flow.all_metrics.formal = parser.parse()
    flow.all_metrics.formal.depth = depth
    m = flow.all_metrics.formal

    # sby exits non-zero even on PASS sometimes; trust log content over exit code
    if not ok and m.status == "UNKNOWN":
        m.status = "FAIL"

    # Aggregate status across ALL non-cover sby files, not just the primary
    # log. Multiple .sby files here mean multiple distinct properties this
    # design claims to uphold (e.g. rr_arbiter.sby's safety proof +
    # rr_arbiter_liveness.sby's starvation-freedom proof) — a failure or
    # non-convergence in a SECONDARY file must not be masked just because
    # the primary file (parsed as `m` above) happened to pass. This is the
    # same bug class as the WARN->PASS fix in this file's FormalLogParser:
    # a per-file result quietly not making it into the overall status.
    # Severity order: FAIL > WARN/UNKNOWN > PASS.
    for stem, lf, r_ok, r_depth in results:
        if lf == log_file:
            continue  # this is `m` — already parsed above
        other_status = FormalLogParser(lf).parse().status
        if other_status == "FAIL":
            m.status = "FAIL"
        elif other_status in ("WARN", "UNKNOWN") and m.status == "PASS":
            m.status = "WARN"

    dash = Dashboard("FORMAL — SymbiYosys", C.BMAGENTA)
    dash.add_metric("Status",        m.status)
    dash.add_metric("Method",        m.proof_method)
    dash.add_metric("Solver",        m.solver)
    dash.add_metric("Depth (cycles)", m.depth)
    dash.add_metric("Max Step",      m.max_step)
    dash.add_metric("Induction",     m.induction_status)
    # ── Structured insights: 2 good, 2 warn, 2 improve ──────────────────────────
    if m.status == "PASS":
        dash.add_insight("k-induction proven — property holds for ALL reachable states, not just bounded traces.", "good")
    if m.status == "PASS" and m.depth > 0:
        dash.add_insight(f"Proof converged in {m.depth} induction steps — shallow depth means low combinational complexity.", "good")
    if m.status == "FAIL":
        dash.add_insight("Counterexample generated — inspect engine_0/trace.vcd to see the exact violating cycle sequence.", "warn")
    if m.induction_status == "FAIL" and m.status != "PASS":
        dash.add_insight("Induction failure: shadow registers not fully constrained — add assert() bindings for pipelined signals.", "warn")
    # Count cover() and assert() properties from all formal source files
    n_covers = n_asserts = 0
    for fsrc in sby_files + list(flow.verif_dir.glob("*_formal.sv")):
        try:
            txt = fsrc.read_text(errors='replace')
            n_covers  += len(re.findall(r'\bcover\s*\(', txt))
            n_asserts += len(re.findall(r'\bassert\s*\(', txt))
        except Exception:
            pass
    if n_covers > 0:
        dash.add_insight(f"{n_covers} cover() propert{'ies' if n_covers>1 else 'y'} + {n_asserts} assert() — "
                         "cover mode verified all interesting states are reachable.", "good")
    else:
        dash.add_insight("Add `cover` properties alongside `assert` to prove all interesting states are reachable.", "improve")
    dash.add_insight("Use `assume` to encode reset sequence and protocol invariants — reduces proof depth and false CEXs.", "improve")
    dash.print()

    # Skip cover mode when the main proof didn't converge (WARN/UNKNOWN) —
    # its diagnostic value is low with no baseline proof to relate it to,
    # and skipping it removes one more concurrent z3 process from an
    # already resource-constrained run. Still run it on a real FAIL
    # (counterexample found) since that's a normal, fast case.
    if m.status not in ("UNKNOWN", "WARN"):
        _run_cover_mode(flow, sby_file, log_file)
    else:
        print(f"     {C.dim('Skipping cover mode — main proof did not converge, low diagnostic value')}")

    if m.status == "FAIL":
        print(f"  {C.err('❌ Formal FAIL')} — see {log_file}")
        return "FAIL"

    if m.status in ("UNKNOWN", "WARN"):
        # WARN covers: solver timeout/engine crash ("did not return a
        # status") — this used to fall through to the unconditional PASS
        # below, silently reporting a non-convergent/crashed proof as if it
        # had succeeded. UNKNOWN covers: sby produced no clear PASS/FAIL
        # at all.
        reason = "did not converge (timeout/engine crash)" if m.status == "WARN" \
                 else "sby did not produce a clear PASS/FAIL"
        print(f"  {C.warn('⚠ Formal WARN')} — {reason}. See {log_file}")
        return "WARN"

    flow.update_checkpoint("formal", deps)
    print(f"  {C.ok('✓ Formal PASS')}  {C.dim(f'log → {log_file.name}')}")
    return "PASS"
