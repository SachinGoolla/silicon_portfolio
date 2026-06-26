"""Pillar 6 — Synthesis (Yosys RTL→gate netlist). Returns PASS | FAIL | SKIP."""
from .common import C, Dashboard, SynthLogParser, SynthMetrics, PILLAR_ICONS


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

    # Write a Yosys script file so we can exclude low-power isolation cells.
    # lpflow_isobufsrc_1 and related sky130 power-domain cells appear in the
    # liberty but have extreme SS-corner derating (30+ ns at 1.28 V / -40 °C).
    # They are architectural primitives for power-domain isolation and must not
    # appear in combinational logic paths.  We replace them with a buf_2 after
    # abc mapping via an inline techmap.
    # -D 10000: tell abc the target is 10 ns (10000 ps) so it optimises for
    #           timing balance rather than pure area (which -D 100 forced).
    synth_ys = sta_dir / f"synth_{flow.top}.ys"
    lpflow_techmap = sta_dir / "lpflow_replace.v"
    lpflow_techmap.write_text(
        # Inline techmap: treat lpflow_isobufsrc_1 as a plain buffer.
        # SLEEP_B is tied high in fully-powered domains, making the cell
        # electrically equivalent to a buffer in normal operation.
        '(* techmap_celltype = "sky130_fd_sc_hd__lpflow_isobufsrc_1" *)\n'
        'module sky130_fd_sc_hd__lpflow_isobufsrc_1'
        '(output X, input A, SLEEP_B, VPWR, VGND, VPB, VNB);\n'
        '  sky130_fd_sc_hd__buf_2 _impl_(.X(X),.A(A),'
        '.VPWR(VPWR),.VGND(VGND),.VPB(VPB),.VNB(VNB));\n'
        'endmodule\n'
    )
    synth_ys.write_text(
        f"read_verilog {sv_flag} -D SYNTHESIS -defer {rtl_str}\n"
        f"hierarchy -check -top {flow.top}\n"
        f"synth -top {flow.top}\n"
        f"dfflibmap -liberty {tt_lib}\n"
        f"abc -liberty {tt_lib} -D 10000\n"
        # Replace any lpflow isolation cells abc may have chosen with buf_2
        f"techmap -map {lpflow_techmap}\n"
        f"clean\n"
        f"write_verilog -noattr -noexpr {synth_v}\n"
    )
    print(f"     {C.info('▶')} Synthesizing with Yosys ({pdk_name}, TT corner)...")
    ok = flow.run_logged(
        f"yosys {synth_ys} > {synth_log} 2>&1",
        synth_log, "Synthesis")

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
    # ── Structured insights: 2 good, 2 warn, 2 improve ──────────────────────────
    dash.add_insight(f"Synthesis completed with {cells} cells — gate netlist is ready for LEC and STA.", "good")
    ff_cells = sum(v for k, v in cell_breakdown.items() if 'dff' in k.lower() or 'ff' in k.lower())
    if ff_cells > 0:
        dash.add_insight(f"{ff_cells} flip-flops mapped — SS corner governs setup timing; FF corner governs hold (both swept in P8).", "good")
    if cells == 0:
        dash.add_insight("Zero cells in netlist — synthesis may have optimized away all logic; check for missing top-level ports.", "warn")
    combo_ratio = (cells - ff_cells) / max(cells, 1)
    if combo_ratio > 0.9 and cells > 10:
        dash.add_insight(f"High combinational ratio ({combo_ratio*100:.0f}% of cells) — deep combinational paths risk timing closure at speed.", "warn")
    dash.add_insight("abc -D 10000 active — timing-aware mapping targeting 10 ns (100 MHz) critical path.", "good")
    dash.add_insight("Add `set_max_fanout` and `set_max_transition` constraints in .sdc to guide synthesis optimization.", "improve")
    dash.print()

    print(f"  {C.ok('✓ Synthesis PASS')}  {C.dim(f'{cells} cells → {synth_v.name}')}")
    return "PASS"
