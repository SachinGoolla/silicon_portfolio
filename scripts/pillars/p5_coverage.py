"""Pillar 5 — Coverage (verilator_coverage). Returns PASS | FAIL | SKIP | WARN."""
import re
import subprocess
from .common import C, Dashboard, CoverageMetrics, PILLAR_ICONS


def run(flow, threshold: int = 0, toggle_threshold: int = 0) -> str:
    """threshold: minimum line coverage %; toggle_threshold: minimum toggle % (0=advisory)."""
    print(f"\n  {C.hdr('━━━ PILLAR 5: Coverage')}  {PILLAR_ICONS[4]}  {C.dim(flow.top)}")

    cov_dat = flow.build_dir / "sim" / "coverage.dat"
    if not cov_dat.exists():
        print(f"     {C.warn('⚠ Skipped')} — no coverage.dat; run Pillar 4 first")
        return "SKIP"

    print(f"     {C.info('▶')} Annotating coverage data...")
    anno_dir = flow.log_dir / "annotated_cov"
    anno_dir.mkdir(exist_ok=True)

    try:
        subprocess.run(f"verilator_coverage --annotate {anno_dir} {cov_dat}",
                       shell=True, check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        print(f"     {C.warn('⚠ verilator_coverage failed:')} {e}")
        return "WARN"

    # Verilator --annotate format: "[%~ ]NNNNNN  <code>" where NNNNNN is a 6-digit zero-padded hit count.
    #   " NNNNNN  <code>"  — executable line; count = times hit
    #   "%NNNNNN  <code>"  — conditional coverage (ports/interfaces); count = times hit
    #   "~NNNNNN  <code>"  — constant expression (structurally uncoverable) — skip
    #   "         <code>"  — non-executable (comments, blank, declarations) — skip
    # A line is UNCOVERED iff count == 0 (all six zeros) AND prefix != '~'.
    _ANNO_RE = re.compile(r'^([%~ ]?)(\d{6})\s+(.+)')
    uncovered = []
    total_lines = 0
    for f in list(anno_dir.rglob("*.sv")) + list(anno_dir.rglob("*.v")):
        # Skip testbench files in the annotated output
        if flow.verif_dir.name in str(f) or 'tb_' in f.name:
            continue
        lines = f.read_text(errors='replace').splitlines()
        # Collect all coverable lines for this file first so we can detect
        # uninstantiated modules (compiled by Verilator but never in the DUT
        # hierarchy — every coverable line has count=0).
        file_rows = []
        for i, line in enumerate(lines):
            m = _ANNO_RE.match(line)
            if not m:
                continue
            prefix, count_str, code = m.group(1), m.group(2), m.group(3).strip()
            if prefix == '~':
                continue  # constant expression — structurally uncoverable
            if not code or code.startswith('//') or code.startswith('/*'):
                continue
            file_rows.append((i + 1, int(count_str), code))
        # Skip uninstantiated modules: if every coverable line is zero the
        # module was compiled but never placed in the design hierarchy.
        if file_rows and all(cnt == 0 for _, cnt, _ in file_rows):
            continue
        for lineno, cnt, code in file_rows:
            total_lines += 1
            if cnt == 0:
                uncovered.append((f.name, lineno, code))

    flow.all_metrics.coverage.uncovered_lines      = uncovered[:20]
    flow.all_metrics.coverage.total_lines_analyzed = total_lines
    n_uncov = len(uncovered)
    pct = int(((total_lines - n_uncov) / total_lines * 100)) if total_lines > 0 else 100
    flow.all_metrics.coverage.line_coverage_pct = float(pct)

    # Parse toggle coverage directly from coverage.dat (v_toggle entries)
    toggle_pct = 0.0
    uncovered_toggles: list = []
    if cov_dat.exists():
        toggle_total = toggle_covered = 0
        for line in cov_dat.read_text(errors='replace').splitlines():
            if 'v_toggle' not in line:
                continue
            # Only count RTL signals (skip testbench)
            if flow.verif_dir.name in line or '/verification/' in line:
                continue
            toggle_total += 1
            # Count is the integer at end of line after the closing quote+space
            m = re.search(r"'\s+(\d+)\s*$", line)
            covered = m and int(m.group(1)) > 0
            if covered:
                toggle_covered += 1
            else:
                # Extract signal path for drill-down display
                sig_m = re.search(r"'([^']+)'\s+\d*\s*$", line)
                sig_name = sig_m.group(1) if sig_m else line.strip()[-40:]
                uncovered_toggles.append(sig_name)
        if toggle_total > 0:
            toggle_pct = round(toggle_covered / toggle_total * 100, 1)
    flow.all_metrics.coverage.toggle_coverage_pct = toggle_pct

    # Parse expression/branch coverage from v_expr entries (requires --coverage-expr in P4)
    expr_pct = None  # None = not collected (--coverage-expr not used)
    if cov_dat.exists():
        expr_total = expr_covered = 0
        for line in cov_dat.read_text(errors='replace').splitlines():
            if 'v_expr' not in line:
                continue
            if flow.verif_dir.name in line or '/verification/' in line:
                continue
            expr_total += 1
            m = re.search(r"'\s+(\d+)\s*$", line)
            if m and int(m.group(1)) > 0:
                expr_covered += 1
        if expr_total > 0:
            expr_pct = round(expr_covered / expr_total * 100, 1)
    if expr_pct is not None:
        flow.all_metrics.coverage.branch_coverage_pct = expr_pct

    dash = Dashboard("COVERAGE — Verilator", C.BYELLOW)
    dash.add_metric("Line Coverage",    f"{pct}%",
                    value_color=C.BGREEN if pct == 100 else (C.BYELLOW if pct >= 80 else C.BRED))
    dash.add_metric("Toggle Coverage",  f"{toggle_pct}%",
                    value_color=C.BGREEN if toggle_pct == 100 else (C.BYELLOW if toggle_pct >= 80 else C.BRED))
    if expr_pct is not None:
        dash.add_metric("Expr Coverage",  f"{expr_pct}%",
                        value_color=C.BGREEN if expr_pct == 100 else (C.BYELLOW if expr_pct >= 80 else C.BRED))
    else:
        dash.add_metric("Branch/Expr",  "N/A — add --coverage-expr to P4 to enable")
    dash.add_metric("Uncovered Lines",  n_uncov,
                    value_color=C.BRED if n_uncov > 0 else C.BGREEN)
    dash.add_metric("Total Lines",      total_lines)
    if threshold > 0:
        dash.add_metric("Line Threshold",  f"{threshold}%",
                        value_color=C.BGREEN if pct >= threshold else C.BRED)
    if toggle_threshold > 0:
        dash.add_metric("Toggle Threshold", f"{toggle_threshold}%",
                        value_color=C.BGREEN if toggle_pct >= toggle_threshold else C.BRED)
    if uncovered_toggles and toggle_pct < 100.0:
        dash.add_section_header(f"Uncovered Toggles ({len(uncovered_toggles)} signals)")
        for sig in uncovered_toggles[:8]:
            dash.add_row("no toggle", sig[-50:])
    if uncovered:
        dash.add_section_header("Top Uncovered")
        for fname, lnum, code in uncovered[:5]:
            dash.add_row(f"{fname}:{lnum}", code[:28])
    # ── Structured insights: 2 good, 2 warn, 2 improve ──────────────────────────
    if n_uncov == 0:
        dash.add_insight("Full line coverage achieved — every RTL statement was exercised during simulation.", "good")
    if pct >= 80:
        dash.add_insight(f"{pct:.1f}% line coverage meets typical pre-tapeout closure target of 80%+.", "good")
    if n_uncov > 5:
        dash.add_insight(f"{n_uncov} uncovered lines — unreachable reset and error paths will cause synthesis optimization divergence.", "warn")
    if pct < 50:
        dash.add_insight(f"Coverage below 50% ({pct:.1f}%) — simulation stimulus is insufficient; most RTL branches are untested.", "warn")
    dash.add_insight("FSM arc coverage requires explicit cover() properties in RTL — Verilator has no native FSM coverage instrumentation.", "improve")
    dash.add_insight("Cross-reference uncovered lines with formal cover() properties to identify truly unreachable states.", "improve")
    dash.print()

    print(f"  {C.ok('✓ Coverage analysis done')}  {C.dim(f'annotated → {anno_dir}')}")

    if threshold > 0 and pct < threshold:
        print(f"  {C.err('❌ Coverage FAIL')} — line {pct}% < threshold {threshold}%")
        return "FAIL"
    if toggle_threshold > 0 and toggle_pct < toggle_threshold:
        print(f"  {C.err('❌ Coverage FAIL')} — toggle {toggle_pct}% < threshold {toggle_threshold}%")
        return "FAIL"

    return "PASS"
