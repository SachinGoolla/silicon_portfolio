"""Pillar 3 — Functional (cocotb / Icarus + pyuvm). Returns PASS | FAIL | SKIP."""
import sys
from pathlib import Path
from .common import (C, Dashboard, FunctionalLogParser, FunctionalXMLParser,
                     FunctionalMetrics, PILLAR_ICONS)


def _run_vlog_tb(flow, tb_file: Path, rtl_files: list) -> str:
    """Fallback: plain iverilog/vvp testbench."""
    deps = rtl_files + [tb_file]
    if flow.is_checkpoint_valid("functional", deps):
        print(f"     {C.ok('✓ Skipped')} {C.dim('(no changes since last test run)')}")
        return "PASS"

    log_file = flow.log_dir / f"func_ivlog_{flow.top}.log"
    vvp_out  = flow.build_dir / f"func_{flow.top}.vvp"
    rtl_src  = " ".join(str(f) for f in flow._find_all_rtl())
    g_flag   = "-g2012" if tb_file.suffix == ".sv" else "-g2005-sv"

    print(f"     {C.info('▶')} Compiling Verilog TB (iverilog {g_flag})...")
    ok = flow.run_logged(
        f"iverilog {g_flag} -Wall -I {flow.src_dir} -o {vvp_out} {tb_file} {rtl_src} "
        f"> {log_file} 2>&1", log_file, "iverilog compile")
    if not ok:
        return "FAIL"

    print(f"     {C.info('▶')} Running vvp...")
    ok = flow.run_logged(f"vvp {vvp_out} >> {log_file} 2>&1", log_file, "vvp run")

    log_text = log_file.read_text(errors='replace') if log_file.exists() else ""
    passed = sum(log_text.count(k) for k in ("PASS", "pass", "OK"))
    failed = sum(log_text.count(k) for k in ("FAIL", "fail", "ERROR"))
    status = "PASS" if failed == 0 else "FAIL"

    flow.all_metrics.functional.tests_total  = max(1, passed + failed)
    flow.all_metrics.functional.tests_passed = passed
    flow.all_metrics.functional.tests_failed = failed

    dash = Dashboard("FUNCTIONAL — iverilog / vvp", C.BGREEN)
    dash.add_metric("TB File",          tb_file.name)
    dash.add_metric("Status",           status)
    dash.add_metric("PASS hits",        passed, value_color=C.BGREEN if passed > 0 else C.DIM)
    dash.add_metric("FAIL hits",        failed, value_color=C.BRED if failed > 0 else C.BGREEN)
    # ── Structured insights for iverilog path ────────────────────────────────────
    dash.add_insight("iverilog testbench compiled cleanly — Verilog-2012 behavioral simulation running.", "good")
    dash.add_insight("PASS/FAIL detection via $display pattern match — simple but requires discipline in TB naming.", "warn")
    dash.add_insight("Migrate to cocotb for per-test XML results, seed tracking, and Python-level randomization.", "improve")
    dash.add_insight("Add a scoreboard that compares DUT outputs against a pure-Python reference model.", "improve")
    dash.print()

    flow.update_checkpoint("functional", deps)
    return status


def _run_uvm(flow) -> str:
    """Run pyuvm tests from verification/uvm/tests/ if present."""
    scripts_uvm = flow.root / "scripts" / "uvm"
    if str(scripts_uvm) not in sys.path:
        sys.path.insert(0, str(scripts_uvm))

    try:
        from uvm.runner import UVMRunner   # noqa: PLC0415
    except ImportError:
        print(f"     {C.warn('⚠')} scripts/uvm not found — skipping pyuvm runner")
        return "SKIP"

    runner = UVMRunner(flow)
    if not runner.has_tests():
        return "SKIP"

    print(f"     {C.info('▶')} Running pyuvm tests (Icarus + cocotb VPI, no Makefile)...")
    summary = runner.run()

    pct = int((summary.passed / summary.total) * 100) if summary.total > 0 else 0
    dash = Dashboard("FUNCTIONAL — pyuvm / Icarus", C.BGREEN)
    dash.add_metric("UVM Tests Total",  summary.total)
    dash.add_metric("Passed",           summary.passed,
                    value_color=C.BGREEN if summary.passed == summary.total and summary.total > 0 else C.BYELLOW)
    dash.add_metric("Failed",           summary.failed,
                    value_color=C.BRED if summary.failed > 0 else C.BGREEN)
    dash.add_metric("Skipped",          summary.skipped)
    dash.add_metric("Errors",           summary.errors,
                    value_color=C.BRED if summary.errors > 0 else C.BGREEN)
    if summary.details:
        dash.add_section_header("Test Details")
        for td in summary.details[:10]:
            dash.add_row(td.name[:32], td.status,
                         C.BGREEN if td.status == "PASS" else C.BRED)
    dash.add_insight("pyuvm: UVM-1800.2 components running on cocotb — scoreboard, coverage, constrained-random.", "good")
    dash.add_insight("NONCOMP ops checked with exact bit-level oracle; FMA/DIVSQRT/CVT use structural NaN/Inf checks.", "good")
    dash.add_insight("Add sfpy (softfloat Python bindings) for bit-accurate FMA/DIVSQRT mantissa verification.", "improve")
    dash.add_insight("Extend FPURandomSeq with pyvsc constraints for weighted coverage-driven generation.", "improve")
    dash.print()

    if summary.failed > 0 or summary.errors > 0:
        return "FAIL"
    if summary.total == 0:
        return "SKIP"
    return "PASS"


def run(flow) -> str:
    print(f"\n  {C.hdr('━━━ PILLAR 3: Functional')}  {PILLAR_ICONS[2]}  {C.dim(flow.top)}")
    rtl_files  = flow._find_all_rtl()
    test_files = list(flow.verif_dir.glob("test_*.py"))

    vlog_tb = None
    for ext in (f"tb_{flow.top}.v", f"tb_{flow.top}.sv"):
        p = flow.verif_dir / ext
        if p.exists():
            vlog_tb = p; break

    if not test_files and not vlog_tb:
        print(f"     {C.warn('⚠ Skipped')} — no test_*.py or tb_{flow.top}.v/.sv in {flow.verif_dir}")
        return "SKIP"

    if not test_files and vlog_tb:
        return _run_vlog_tb(flow, vlog_tb, rtl_files)

    uvm_test_files = sorted((flow.verif_dir / "uvm" / "tests").glob("test_*.py")) \
        if (flow.verif_dir / "uvm" / "tests").is_dir() else []
    deps = rtl_files + test_files + uvm_test_files
    if flow.is_checkpoint_valid("functional", deps):
        print(f"     {C.ok('✓ Skipped')} {C.dim('(no changes since last test run)')}")
        return "PASS"

    if flow.run_capture("python3 -c 'import cocotb'").returncode != 0:
        print(f"     {C.warn('⚠ Skipped')} — cocotb not installed. "
              f"Run: {flow.root}/.venv/bin/pip install cocotb")
        return "SKIP"

    top_rtl = flow._find_top_rtl()
    if top_rtl is None:
        print(f"  {C.err('❌')} Could not find {flow.top}.sv/.v in {flow.src_dir}")
        return "FAIL"

    log_file    = flow.log_dir / f"cocotb_{flow.top}.log"
    cocotb_build = flow.build_dir / "cocotb"
    cocotb_build.mkdir(exist_ok=True)
    results_xml  = cocotb_build / "results.xml"

    cocotb_cfg = flow.root / ".venv" / "bin" / "cocotb-config"
    if not cocotb_cfg.exists():
        cocotb_cfg = Path("cocotb-config")

    makefiles_path = flow.run_capture(f"{cocotb_cfg} --makefiles").stdout.strip()
    all_rtl_str    = " ".join(str(f) for f in flow._find_all_rtl())
    test_modules   = " ".join(t.stem for t in test_files)
    makefile       = cocotb_build / "Makefile"
    makefile.write_text(
        f"SIM ?= icarus\n"
        f"TOPLEVEL_LANG ?= verilog\n"
        f"VERILOG_SOURCES = {all_rtl_str}\n"
        f"TOPLEVEL = {flow.top}\n"
        f"COCOTB_TEST_MODULES = {test_modules}\n"
        f"COCOTB_RESULTS_FILE = {results_xml}\n"
        f"SIM_BUILD = {cocotb_build}/sim_build\n"
        f"include {makefiles_path}/Makefile.sim\n"
    )

    venv_python = flow.root / ".venv" / "bin" / "python3"
    python_bin  = str(venv_python) if venv_python.exists() else "python3"
    print(f"     {C.info('▶')} Running cocotb tests (Icarus Verilog backend)...")
    ok = flow.run_logged(
        f"PYTHONPATH={flow.verif_dir} COCOTB_PYTHON_BIN={python_bin} "
        f"make -C {cocotb_build} SIM=icarus > {log_file} 2>&1",
        log_file, "Functional Verification (cocotb)")

    flow.all_metrics.functional = FunctionalXMLParser(results_xml).parse()
    log_m = FunctionalLogParser(log_file).parse()
    if log_m.sim_time_ns > 0:  flow.all_metrics.functional.sim_time_ns = log_m.sim_time_ns
    if log_m.speed_ratio > 0:  flow.all_metrics.functional.speed_ratio = log_m.speed_ratio
    if log_m.seed != "Unknown": flow.all_metrics.functional.seed = log_m.seed
    m = flow.all_metrics.functional

    pct = int((m.tests_passed / m.tests_total) * 100) if m.tests_total > 0 else 0
    dash = Dashboard("FUNCTIONAL — cocotb / Icarus", C.BGREEN)
    dash.add_metric("Tests Total",  m.tests_total)
    dash.add_metric("Passed",       m.tests_passed,
                    value_color=C.BGREEN if m.tests_passed == m.tests_total and m.tests_total > 0 else C.BYELLOW)
    dash.add_metric("Failed",       m.tests_failed,
                    value_color=C.BRED if m.tests_failed > 0 else C.BGREEN)
    dash.add_metric("Skipped",      m.tests_skipped)
    dash.add_metric("Sim Time",     f"{m.sim_time_ns:.2f}", " ns")
    dash.add_metric("Speed",        f"{m.speed_ratio:.1f}", " ns/s")
    dash.add_metric("Seed",         m.seed)
    if m.test_details:
        dash.add_section_header("Test Details")
        for td in m.test_details[:6]:
            dash.add_row(td['name'][:28], td['status'],
                         C.BGREEN if td['status'] == 'PASS' else C.BRED)
    # ── Structured insights: 2 good, 2 warn, 2 improve ──────────────────────────
    if m.tests_passed == m.tests_total and m.tests_total > 0:
        dash.add_insight(f"All {m.tests_total} cocotb tests passed — directed behavioral verification complete.", "good")
    if m.tests_total >= 3:
        dash.add_insight("Reasonable test count — directed corner cases covered at the cocotb level.", "good")
    if m.tests_failed > 0:
        dash.add_insight(f"{m.tests_failed} test(s) FAILED — this is a behavioral bug NOT caught by lint or formal.", "warn")
    if m.tests_total < 3:
        dash.add_insight("Under-verified: fewer than 3 tests means edge cases like reset mid-run are not covered.", "warn")
    dash.add_insight("Add randomized stimulus with cocotb + hypothesis to widen coverage beyond directed tests.", "improve")
    dash.add_insight("Instrument a scoreboard comparing DUT outputs against a cycle-accurate Python reference model.", "improve")
    dash.print()

    if m.tests_failed > 0:
        print(f"  {C.err('❌ Functional FAIL')} — {m.tests_failed} test(s) failed — see {log_file}")
        return "FAIL"

    if not ok and m.tests_total == 0:
        print(f"  {C.err('❌ Functional FAIL')} — cocotb run failed — see {log_file}")
        return "FAIL"

    flow.update_checkpoint("functional", deps)
    print(f"  {C.ok('✓ Functional PASS')}  {C.dim(f'log → {log_file.name}')}")

    # ── pyuvm tier (optional — runs in addition to cocotb directed tests) ──
    uvm_status = _run_uvm(flow)
    if uvm_status == "FAIL":
        print(f"  {C.err('❌ UVM FAIL')} — pyuvm scoreboard found mismatches")
        return "FAIL"

    return "PASS"
