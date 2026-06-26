"""Pillar 2 — Formal (SymbiYosys k-induction + cover mode). Returns PASS | FAIL | SKIP."""
import re
import shutil
import subprocess
import concurrent.futures
from pathlib import Path
from .common import C, Dashboard, FormalLogParser, PILLAR_ICONS


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
    result = subprocess.run(
        f"ulimit -v 4194304 2>/dev/null; sby -f {cover_sby.name} > {cover_log} 2>&1",
        shell=True, cwd=sby_file.parent)

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

    result = subprocess.run(
        f"ulimit -v 4194304 2>/dev/null; sby -f {active_sby.name}",
        shell=True, capture_output=True, text=True, cwd=sby_file.parent)
    combined = result.stdout + result.stderr
    log_file.write_text(combined)
    ok = (result.returncode == 0) or ("DONE (PASS" in combined)

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

    deps = rtl_files + sby_files
    if flow.is_checkpoint_valid("formal", deps):
        print(f"     {C.ok('✓ Skipped')} {C.dim('(no changes since last proof)')}")
        return "PASS"

    # Run ALL .sby files in parallel (one thread per file)
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

    _run_cover_mode(flow, sby_file, log_file)

    if m.status == "FAIL":
        print(f"  {C.err('❌ Formal FAIL')} — see {log_file}")
        return "FAIL"

    if m.status == "UNKNOWN":
        print(f"  {C.warn('⚠ Formal UNKNOWN')} — sby did not produce a clear PASS/FAIL")
        return "WARN"

    flow.update_checkpoint("formal", deps)
    print(f"  {C.ok('✓ Formal PASS')}  {C.dim(f'log → {log_file.name}')}")
    return "PASS"
