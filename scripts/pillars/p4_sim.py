"""Pillar 4 — Simulation (Verilator binary + VCD + coverage.dat). Returns PASS | FAIL | SKIP."""
from .common import C, Dashboard, SimLogParser, PILLAR_ICONS


def run(flow) -> str:
    print(f"\n  {C.hdr('━━━ PILLAR 4: Simulation')}  {PILLAR_ICONS[3]}  {C.dim(flow.top)}")

    tb_file = None
    for ext in (f"tb_{flow.top}.sv", f"tb_{flow.top}.v"):
        p = flow.verif_dir / ext
        if p.exists():
            tb_file = p; break

    if tb_file is None:
        print(f"     {C.warn('⚠ Skipped')} — no tb_{flow.top}.sv/.v in {flow.verif_dir}")
        print(f"     {C.dim('See scripts/tb_template.sv for a self-checking testbench template.')}")
        return "SKIP"

    rtl_files = flow._find_all_rtl()
    deps      = rtl_files + [tb_file]
    if flow.is_checkpoint_valid("sim", deps):
        print(f"     {C.ok('✓ Skipped')} {C.dim('(no changes since last simulation)')}")
        vcd = flow.build_dir / "sim" / f"tb_{flow.top}.vcd"
        if vcd.exists():
            flow._open_vcd(vcd)
        return "PASS"

    top_rtl = flow._find_top_rtl()
    if top_rtl is None:
        print(f"  {C.err('❌')} Could not find {flow.top}.sv/.v in {flow.src_dir}")
        return "FAIL"

    print(f"     {C.info('▶')} Compiling with Verilator (--binary --timing --coverage --trace)...")
    sim_dir  = flow.build_dir / "sim"
    sim_dir.mkdir(exist_ok=True)
    log_file = flow.log_dir / f"sim_{flow.top}.log"
    fst_out  = sim_dir / f"tb_{flow.top}.fst"   # FST: 4-8x smaller than VCD
    cov_dat  = sim_dir / "coverage.dat"
    obj_dir  = sim_dir / f"obj_dir_{flow.top}"
    sv_flag  = "--sv" if top_rtl.suffix == ".sv" else ""
    rtl_src  = " ".join(str(f) for f in flow._find_all_rtl())

    # RTL parameter overrides: --params KEY=VAL → Verilator -GKEY=VAL
    param_flags = " ".join(f"-G{k}={v}" for k, v in flow.params.items())
    log_file.write_text("")  # truncate so SimLogParser only sees this run's output
    compile_cmd = (
        f"verilator --binary --assert --coverage --coverage-toggle --coverage-expr --trace-fst --timing {sv_flag} "
        f"-y {flow.src_dir} --Mdir {obj_dir} --top-module tb_{flow.top} "
        f"{tb_file} {rtl_src} {param_flags} -CFLAGS '-O2' >> {log_file} 2>&1"
    )
    run_cmd = (
        f"{obj_dir}/Vtb_{flow.top} +fst={fst_out} "
        f"'+verilator+coverage+file+{cov_dat}' >> {log_file} 2>&1"
    )
    ok = flow.run_logged(f"({compile_cmd}) && ({run_cmd})", log_file, "Simulation")

    parser = SimLogParser(log_file)
    flow.all_metrics.sim = parser.parse()
    m = flow.all_metrics.sim

    fst_size_mb = fst_out.stat().st_size / (1024 * 1024) if fst_out.exists() else 0.0
    m.vcd_size_mb = fst_size_mb  # reuse field — it's the waveform file size
    exe = obj_dir / f"Vtb_{flow.top}"
    if exe.exists():
        m.exe_size_mb = exe.stat().st_size / (1024 * 1024)

    dash = Dashboard("SIMULATION — Verilator", C.BBLUE)
    dash.add_metric("Status",       m.status)
    dash.add_metric("Sim End Time", m.sim_end_time, " ps")
    dash.add_metric("Wall Time",    f"{m.wall_time:.3f}", "s")
    dash.add_metric("Memory",       f"{m.memory_mb:.1f}", "MB")
    dash.add_metric("FST Size",     f"{fst_size_mb:.3f}", " MB")
    # ── Structured insights: 2 good, 2 warn, 2 improve ──────────────────────────
    if m.status == "PASS":
        dash.add_insight("No $error/$fatal triggered — simulation ran to $finish without self-check failures.", "good")
    if m.wall_time < 5.0:
        dash.add_insight(f"Fast sim: {m.wall_time:.2f}s wall time — regression-friendly, can run on every commit.", "good")
    if fst_size_mb > 50:
        dash.add_insight(f"FST is {fst_size_mb:.1f} MB — add --trace-depth 2 to limit signal hierarchy depth.", "warn")
    if m.status == "FAIL":
        dash.add_insight("$error/$fatal fired — behavioral mismatch caught in simulation; check waveform for cycle.", "warn")
    dash.add_insight("FST format active — open with GTKWave or Surfer; 4-8x smaller than VCD with identical signal fidelity.", "good")
    dash.add_insight("$finish alone does not prove correctness — add $error assertions on every expected output to harden self-check.", "improve")
    dash.print()

    if m.status == "FAIL" or not ok:
        print(f"  {C.err('❌ Simulation FAIL')} — $error/$fatal detected — see {log_file}")
        return "FAIL"

    flow.update_checkpoint("sim", deps)
    flow.archive_artifact(fst_out, "FST")
    print(f"  {C.ok('✓ Simulation PASS')}  {C.dim(f'log → {log_file.name}')}")
    flow._open_vcd(fst_out)
    return "PASS"
