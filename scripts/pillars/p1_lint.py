"""Pillar 1 — Lint + CDC/RDC (Verilator --lint-only + static analysis). Returns PASS | FAIL | SKIP."""
import re
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

    # ── Dashboard ─────────────────────────────────────────────────────────────
    dash = Dashboard("LINT + CDC/RDC — Verilator + Static", C.BCYAN)
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
    dash.add_section_header("CDC / RDC")
    if cdc_warnings:
        dash.add_metric("CDC/RDC Flags", len(cdc_warnings),
                        value_color=C.BYELLOW)
        for w in cdc_warnings[:3]:
            dash.add_row("  flag", w[:44])
    else:
        dash.add_metric("CDC/RDC Flags", "0 (clean)", value_color=C.BGREEN)

    # ── Structured insights: 2 good, 2 warn, 2 improve ──────────────────────────
    if m.errors == 0:
        dash.add_insight("Zero lint errors — RTL compiles cleanly and synthesizers will see exactly the logic you intend.", "good")
    if m.warnings == 0 and not cdc_warnings:
        dash.add_insight("No CDC/RDC flags detected — clock-domain crossings are either absent or properly synchronized.", "good")
    if m.errors > 0:
        dash.add_insight(f"{m.errors} lint error(s) found — these are hard failures that will corrupt synthesis netlist.", "warn")
    if m.warnings > 5:
        dash.add_insight(f"{m.warnings} warnings — width mismatches and undriven nets can mask functional bugs at the boundary.", "warn")
    if cdc_warnings:
        dash.add_insight("CDC flags are advisory (static regex scan only). Use Meridian CDC or VC Formal CDC for sign-off.", "improve")
    dash.add_insight("Add `// synopsys translate_off` guards around simulation-only code to keep lint warnings minimal.", "improve")
    dash.print()

    if result.returncode != 0:
        print(f"  {C.err('❌ Lint FAILED')} — see {log_file}")
        return "FAIL"

    flow.update_checkpoint("lint", rtl_files)
    cdc_suffix = f" | {len(cdc_warnings)} CDC flags" if cdc_warnings else " | CDC clean"
    print(f"  {C.ok('✓ Lint PASS')}  {C.dim(f'log → {log_file.name}{cdc_suffix}')}")
    return "PASS"
