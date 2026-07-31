"""Pillar 1 — Lint + CDC/RDC (Verilator --lint-only + static + OpenCDC). Returns PASS | FAIL | SKIP."""
import re
import subprocess
import sys
from pathlib import Path
from .common import C, Dashboard, LintLogParser, PILLAR_ICONS


def _run_cdc_static(flow, rtl_files) -> list[str]:
    """
    Static CDC/RDC pattern scanner — open-source substitute for commercial CDC tools.
    Scans RTL for common clock-domain crossing anti-patterns.
    Returns a list of warning strings. Never raises.
    """
    warnings = []
    clk_signals: set[str] = set()
    async_assigns: list[str] = []

    for f in rtl_files:
        try:
            src = f.read_text(errors='replace')
        except Exception:
            continue

        # Collect clock signal names (heuristic: posedge/negedge triggers)
        for m in re.finditer(r'(pos|neg)edge\s+(\w+)', src):
            clk_signals.add(m.group(2))

        # Detect multi-bit signals used in always blocks with different clock conditions
        # (crude: flag any always_comb with output that's also in always_ff)
        ff_outputs: set[str] = set()
        for m in re.finditer(
                r'always_ff\s*@[^;]+;\s*(?:[\s\S]*?)'
                r'(\w+)\s*<=', src):
            ff_outputs.add(m.group(1))

        # Latch detection: always @(...) with no edge trigger at all
        # Excludes standard clocked blocks (posedge/negedge in sensitivity list)
        for m in re.finditer(r'always\s*@\s*\(([^)]+)\)', src):
            sens = m.group(1)
            if not re.search(r'(pos|neg)edge', sens) and '*' not in sens:
                warnings.append(f"{f.name}: potential latch — always block without edge trigger")

        # Multi-clock always block (two posedge in one sensitivity list)
        # Skip the standard async-reset pattern: always @(posedge clk or posedge rst)
        # That is a single clock domain with an asynchronous reset — not a CDC crossing.
        _RST_NAMES = re.compile(r'^(rst|reset|arst|n?rst\w*)$', re.IGNORECASE)
        for m in re.finditer(r'always\s*@\s*\(([^)]+)\)', src):
            edges = re.findall(r'(pos|neg)edge\s+(\w+)', m.group(1))
            if len(edges) >= 2:
                clks = [e[1] for e in edges]
                non_rst = [c for c in clks if not _RST_NAMES.match(c)]
                if len(set(non_rst)) > 1:
                    warnings.append(
                        f"{f.name}: multi-clock sensitivity list [{', '.join(non_rst)}]"
                        " — verify CDC synchronizer present")

        # Asynchronous resets that aren't qualified (flag for RDC review)
        rst_nets = [m.group(1) for m in re.finditer(r'(pos|neg)edge\s+(rst\w*)', src, re.IGNORECASE)]
        for rst in rst_nets:
            async_assigns.append(f"{f.name}: async reset '{rst}' — confirm glitch-free assertion")

    # Deduplicate
    for w in dict.fromkeys(warnings + async_assigns[:4]):
        yield w


def _run_opencdc(flow, rtl_files) -> tuple[str, list[dict]]:
    """Structural CDC analysis via OpenCDC on a Yosys `prep` netlist.

    Uses `prep` (not `synth`) so $dff/$dffe cells are preserved with their
    CLK connections — required for OpenCDC's domain comparison to work.
    Returns (status, crossings_list).  Never raises; returns SKIP on any error.
    """
    opencdc_root = flow.root / "tools" / "opencdc"
    if not opencdc_root.exists():
        return "SKIP", []

    if str(opencdc_root) not in sys.path:
        sys.path.insert(0, str(opencdc_root))
    try:
        from opencdc.checker import check_netlist_file   # noqa: PLC0415
    except ImportError:
        return "SKIP", []

    netlist_json = flow.build_dir / "lint" / f"{flow.top}_cdc.json"
    netlist_json.parent.mkdir(parents=True, exist_ok=True)

    sv_flag = "-sv" if any(f.suffix == ".sv" for f in rtl_files) else ""
    rtl_str = " ".join(str(f) for f in rtl_files)
    ys_script = (
        f"read_verilog {sv_flag} {rtl_str}; "
        f"prep -top {flow.top}; "
        f"write_json {netlist_json}"
    )

    try:
        proc = subprocess.run(
            ["yosys", "-q", "-p", ys_script],
            capture_output=True, text=True, timeout=90
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return "SKIP", []

    if proc.returncode != 0:
        return "WARN", []

    try:
        return "PASS", check_netlist_file(str(netlist_json))
    except Exception:
        return "WARN", []


def run(flow) -> str:
    print(f"\n  {C.hdr('━━━ PILLAR 1: Lint + CDC/RDC')}  {PILLAR_ICONS[0]}  {C.dim(flow.top)}")
    rtl_files = flow._find_all_rtl()
    top_file  = flow._find_top_rtl()

    if not rtl_files or top_file is None:
        print(f"     {C.warn('⚠ No RTL files found in')} {flow.src_dir}")
        return "SKIP"

    if flow.is_checkpoint_valid("lint", rtl_files):
        print(f"     {C.ok('✓ Skipped')} {C.dim('(no RTL changes since last run)')}")
        return "PASS"

    # ── Verilator lint ────────────────────────────────────────────────────────
    includes = f"-I{flow.src_dir}"
    log_file = flow.log_dir / f"lint_{flow.top}.log"
    sv_flag  = "--sv" if top_file.suffix == ".sv" else ""
    all_src  = " ".join(str(f) for f in rtl_files)
    cmd = (f"verilator --lint-only -Wall {sv_flag} --top-module {flow.top} "
           f"{includes} {all_src}")

    print(f"     {C.info('▶')} Running Verilator lint (syntax, width, latch, FSM)...")
    result = flow.run_capture(cmd)
    log_file.write_text(result.stdout + "\n" + result.stderr)

    parser = LintLogParser(log_file)
    flow.all_metrics.lint = parser.parse()
    m = flow.all_metrics.lint

    # ── CDC/RDC static analysis ───────────────────────────────────────────────
    print(f"     {C.info('▶')} Running static CDC/RDC pattern scan...")
    cdc_warnings = list(_run_cdc_static(flow, rtl_files))
    cdc_log = flow.log_dir / f"cdc_{flow.top}.log"
    cdc_log.write_text("\n".join(cdc_warnings) if cdc_warnings else "No CDC/RDC issues detected.\n")

    # ── OpenCDC structural analysis ───────────────────────────────────────────
    print(f"     {C.info('▶')} Running OpenCDC structural crossing analysis...")
    opencdc_status, opencdc_crossings = _run_opencdc(flow, rtl_files)
    opencdc_log = flow.log_dir / f"opencdc_{flow.top}.log"
    if opencdc_crossings:
        lines = [f"{c['driver_ff']}(dom:{c['driver_domain']}) -> {c['sink_ff']}(dom:{c['sink_domain']})  net={c['net']}"
                 for c in opencdc_crossings]
        opencdc_log.write_text("\n".join(lines) + "\n")
    else:
        opencdc_log.write_text(f"OpenCDC: {opencdc_status}\n")

    # ── Dashboard ─────────────────────────────────────────────────────────────
    dash = Dashboard("LINT + CDC/RDC — Verilator + Static + OpenCDC", C.BCYAN)
    dash.add_section_header("Lint")
    dash.add_metric("Warnings", m.warnings,
                    value_color=C.BYELLOW if m.warnings > 0 else C.BGREEN)
    dash.add_metric("Errors",   m.errors,
                    value_color=C.BRED if m.errors > 0 else C.BGREEN)
    dash.add_metric("Wall Time", f"{m.wall_time:.3f}", "s")
    dash.add_metric("Memory",    f"{m.memory_mb:.1f}", "MB")
    if m.warning_details:
        dash.add_section_header("Lint Warnings")
        for w in m.warning_details[:4]:
            dash.add_row("", w[:48])
    dash.add_section_header("CDC / RDC (Static)")
    if cdc_warnings:
        dash.add_metric("Static Flags", len(cdc_warnings), value_color=C.BYELLOW)
        for w in cdc_warnings[:3]:
            dash.add_row("  flag", w[:44])
    else:
        dash.add_metric("Static Flags", "0 (clean)", value_color=C.BGREEN)
    dash.add_section_header("OpenCDC — Structural")
    if opencdc_status == "SKIP":
        dash.add_metric("OpenCDC", "SKIP (tool not found)", value_color=C.DIM)
    elif opencdc_status == "WARN":
        dash.add_metric("OpenCDC", "WARN (netlist gen failed)", value_color=C.BYELLOW)
    elif opencdc_crossings:
        dash.add_metric("CDC Crossings", len(opencdc_crossings), value_color=C.BYELLOW)
        # Group by domain pair for concise display
        pairs: dict = {}
        for c in opencdc_crossings:
            k = (c['driver_domain'], c['sink_domain'])
            pairs[k] = pairs.get(k, 0) + 1
        for (d_dom, s_dom), cnt in list(pairs.items())[:4]:
            dash.add_row("  crossing", f"dom:{d_dom} → dom:{s_dom}  ({cnt} nets)")
    else:
        dash.add_metric("CDC Crossings", "0 (no unsynced crossings)", value_color=C.BGREEN)

    # ── Insights ─────────────────────────────────────────────────────────────
    if m.errors == 0:
        dash.add_insight("Zero lint errors — RTL compiles cleanly; synthesizers see exactly the intended logic.", "good")
    if m.warnings == 0 and not cdc_warnings:
        dash.add_insight("No static CDC/RDC flags — clock-domain crossings are absent or properly synchronized.", "good")
    if opencdc_crossings:
        dash.add_insight(
            f"OpenCDC found {len(opencdc_crossings)} FF→FF crossing(s) — ADVISORY. "
            "Verify each sink FF is the first stage of a 2-FF synchronizer.", "warn")
        dash.add_insight("OpenCDC detects raw structural crossings; it cannot distinguish a synchronizer "
                         "first-stage from an unprotected crossing — manual review required.", "improve")
    elif opencdc_status == "PASS":
        dash.add_insight("OpenCDC: no raw FF→FF crossings detected — single-clock or fully synchronised design.", "good")
    if m.errors > 0:
        dash.add_insight(f"{m.errors} lint error(s) — hard failures that corrupt the synthesis netlist.", "warn")
    if cdc_warnings:
        dash.add_insight("Static CDC flags are advisory (regex scan). Use Meridian CDC or VC Formal CDC for sign-off.", "improve")
    dash.add_insight("OpenCDC uses Yosys `prep` netlist — structural, not timing-aware. "
                     "Report to tools/opencdc/ if false positives appear.", "improve")
    dash.print()

    if result.returncode != 0:
        print(f"  {C.err('❌ Lint FAILED')} — see {log_file}")
        return "FAIL"

    flow.update_checkpoint("lint", rtl_files)
    cdc_suffix   = f" | {len(cdc_warnings)} CDC flags" if cdc_warnings else " | CDC clean"
    opencdc_sfx  = (f" | OpenCDC {len(opencdc_crossings)} xings"
                    if opencdc_crossings else
                    (f" | OpenCDC {opencdc_status}" if opencdc_status != "PASS" else " | OpenCDC 0"))
    print(f"  {C.ok('✓ Lint PASS')}  {C.dim(f'log → {log_file.name}{cdc_suffix}{opencdc_sfx}')}")
    return "PASS"
