"""Pillar 6 — Synthesis (Yosys RTL→gate netlist). Returns PASS | FAIL | SKIP."""
from pathlib import Path
import re as _re
from .common import C, Dashboard, SynthLogParser, SynthMetrics, PILLAR_ICONS


def _filter_liberty_lpflow(src: Path, dst: Path) -> int:
    """Write a copy of *src* liberty with all lpflow_* cells removed.

    Yosys 0.33 abc has no -dont_use flag, so we pre-filter the liberty.
    sky130 lpflow_isobufsrc_1 / lpflow_inputiso1p_1 implement X = A AND NOT(SLEEP).
    abc picks them as cheap AND gates at TT corner, but at SS (-40 °C / 1.28 V)
    they carry 30+ ns derating — destroying timing.  The filtered liberty forces
    abc to use standard nand2/and2 cells, which is an equivalence-preserving
    remapping of the same RTL function.
    Returns the number of cell blocks removed.
    """
    lines = src.read_text().splitlines(keepends=True)
    out, depth, in_skip, removed = [], 0, False, 0
    for line in lines:
        if not in_skip and _re.search(r'\bcell\s*\(\s*"?\s*sky130_fd_sc_hd__lpflow_', line):
            in_skip = True
            removed += 1
            depth = line.count('{') - line.count('}')
            continue
        if in_skip:
            depth += line.count('{') - line.count('}')
            if depth <= 0:
                in_skip = False
            continue
        out.append(line)
    dst.write_text(''.join(out))
    return removed


def run(flow) -> str:
    print(f"\n  {C.hdr('━━━ PILLAR 6: Synthesis')}  {PILLAR_ICONS[5]}  {C.dim(flow.top)}")

    tt_lib, corners, pdk_name = flow._select_lib_files()
    if tt_lib is None:
        print(f"     {C.warn('⚠ Skipped')} — no .lib files in {flow.lib_dir}")
        print(f"     {C.dim('Symlink PDK: ln -s /path/to.lib lib/ — then re-run with --pdk sky130')}")
        return "SKIP"

    sta_dir   = flow.build_dir / "sta"
    sta_dir.mkdir(exist_ok=True)
    synth_v   = sta_dir / f"{flow.top}_synth.v"
    synth_log = flow.log_dir / f"synth_{flow.top}.log"
    top_rtl   = flow._find_top_rtl()
    rtl_str   = " ".join(str(f) for f in flow._find_all_rtl())
    sv_flag   = "-sv" if (top_rtl and top_rtl.suffix == ".sv") else ""

    # Pre-filter the liberty to exclude lpflow power-isolation cells.
    # This is done before abc so it remaps the same logic to standard cells.
    tt_lib_noiso = sta_dir / f"{Path(tt_lib).stem}_nolpflow.lib"
    n_removed = _filter_liberty_lpflow(Path(tt_lib), tt_lib_noiso)
    if n_removed:
        print(f"     {C.info('▶')} Filtered {n_removed} lpflow cells from liberty → {tt_lib_noiso.name}")

    synth_ys = sta_dir / f"synth_{flow.top}.ys"
    synth_ys.write_text(
        f"read_verilog {sv_flag} -D SYNTHESIS -defer {rtl_str}\n"
        f"hierarchy -check -top {flow.top}\n"
        f"synth -top {flow.top}\n"
        f"dfflibmap -liberty {tt_lib}\n"
        f"abc -liberty {tt_lib_noiso} -D 12500\n"
        f"clean\n"
        f"write_verilog -noattr -noexpr {synth_v}\n"
    )
    print(f"     {C.info('▶')} Synthesizing with Yosys ({pdk_name}, TT corner)...")
    ok = flow.run_logged(
        f"yosys {synth_ys} > {synth_log} 2>&1",
        synth_log, "Synthesis", ulimit_v_kb=2 * 1024 * 1024)

    if not ok:
        print(f"  {C.err('❌ Synthesis FAIL')} — see {synth_log}")
        return "FAIL"

    cells, wires, cell_breakdown = SynthLogParser(synth_log).parse()
    sm = SynthMetrics(status="PASS", total_cells=cells, total_wires=wires,
                      cell_breakdown=cell_breakdown)
    flow.all_metrics.synth = sm
    # Mirror into STAMetrics for backward compat (STA dashboard uses these)
    flow.all_metrics.sta.total_cells    = cells
    flow.all_metrics.sta.total_wires    = wires
    flow.all_metrics.sta.cell_breakdown = cell_breakdown

    dash = Dashboard(f"SYNTHESIS — Yosys ({pdk_name})", C.BMAGENTA)
    dash.add_metric("Status",       "PASS",   value_color=C.BGREEN)
    dash.add_metric("PDK",          pdk_name)
    dash.add_metric("Total Cells",  cells)
    dash.add_metric("Total Wires",  wires)
    dash.add_metric("Netlist",      synth_v.name)
    if cell_breakdown:
        dash.add_section_header(f"Cell Mix ({len(cell_breakdown)} types)")
        for cell, count in sorted(cell_breakdown.items(), key=lambda x: -x[1]):
            dash.add_row(cell[:24], str(count))
    # ── Structured insights ───────────────────────────────────────────────────────
    dash.add_insight(f"Synthesis completed with {cells} cells — gate netlist is ready for LEC and STA.", "good")
    ff_cells = sum(v for k, v in cell_breakdown.items() if 'dff' in k.lower() or 'ff' in k.lower())
    if ff_cells > 0:
        dash.add_insight(f"{ff_cells} flip-flops mapped — SS corner governs setup timing; FF corner governs hold (both swept in P8).", "good")
    if n_removed:
        dash.add_insight(f"lpflow isolation cells excluded from abc liberty — standard nand2/and2 used instead (no 30 ns SS derating).", "good")
    if cells == 0:
        dash.add_insight("Zero cells in netlist — synthesis may have optimized away all logic; check for missing top-level ports.", "warn")
    combo_ratio = (cells - ff_cells) / max(cells, 1)
    if combo_ratio > 0.9 and cells > 10:
        dash.add_insight(f"High combinational ratio ({combo_ratio*100:.0f}% of cells) — deep combinational paths risk timing closure at speed.", "warn")
    dash.add_insight("abc -D 12500 active — timing-aware mapping targeting 12.5 ns (80 MHz) critical path.", "good")
    dash.add_insight("Add `set_max_fanout` and `set_max_transition` constraints in .sdc to guide synthesis optimization.", "improve")
    dash.print()

    print(f"  {C.ok('✓ Synthesis PASS')}  {C.dim(f'{cells} cells → {synth_v.name}')}")
    return "PASS"
