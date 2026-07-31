"""
UVMRunner — Makefile-free pyuvm test runner for the pillar flow.

For any IP that has verification/uvm/tests/test_*.py, this runner:
  1. Compiles all RTL once with iverilog + cocotb VPI
  2. Runs each test file with vvp, injecting PYTHONPATH so tests can import
     both pyuvm (from .venv) and the IP-specific UVM components
  3. Parses results.xml and returns (passed, failed, skipped, details)

No Makefiles are generated. All subprocess calls are direct Python.
"""
import os
import re
import subprocess
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class UVMTestResult:
    name:   str
    status: str   # "PASS" | "FAIL" | "SKIP" | "ERROR"
    message: str = ""


@dataclass
class UVMRunSummary:
    passed:  int = 0
    failed:  int = 0
    skipped: int = 0
    errors:  int = 0
    details: list = field(default_factory=list)

    @property
    def total(self):
        return self.passed + self.failed + self.skipped + self.errors

    @property
    def all_passed(self):
        return self.total > 0 and self.failed == 0 and self.errors == 0


class UVMRunner:
    """
    Generic pyuvm test runner.  One instance per IP; call .run() to execute.

    Parameters
    ----------
    flow : PillarFlow
        The active pillar flow (provides .top, .src_dir, .verif_dir,
        .build_dir, .log_dir, .root, .run_logged helpers).
    """

    def __init__(self, flow):
        self.flow      = flow
        self.uvm_dir   = flow.verif_dir / "uvm"
        self.tests_dir = self.uvm_dir / "tests"
        self.build_dir = flow.build_dir / "uvm"
        self.venv_bin  = flow.root / ".venv" / "bin"
        self.python    = self.venv_bin / "python3"

    # ------------------------------------------------------------------ public

    def has_tests(self) -> bool:
        return self.tests_dir.is_dir() and bool(list(self.tests_dir.glob("test_*.py")))

    def run(self) -> UVMRunSummary:
        test_files = sorted(self.tests_dir.glob("test_*.py"))
        if not test_files:
            return UVMRunSummary()

        self.build_dir.mkdir(parents=True, exist_ok=True)

        if not self._compile_rtl():
            summary = UVMRunSummary(errors=1)
            summary.details.append(UVMTestResult("compile", "ERROR", "iverilog compile failed"))
            return summary

        summary = UVMRunSummary()
        for tf in test_files:
            result = self._run_test_file(tf)
            summary.details.extend(result.details)
            summary.passed  += result.passed
            summary.failed  += result.failed
            summary.skipped += result.skipped
            summary.errors  += result.errors

        return summary

    # ----------------------------------------------------------------- private

    def _compile_rtl(self) -> bool:
        """Compile all RTL once.  Re-uses existing sim.vvp if RTL unchanged."""
        rtl_files = self.flow._find_all_rtl()
        vvp_out   = self.build_dir / "sim.vvp"
        cmds_f    = self.build_dir / "cmds.f"
        log       = self.flow.log_dir / f"uvm_compile_{self.flow.top}.log"

        cmds_f.write_text("+timescale+1ns/1ps\n")

        src_list = " ".join(str(f) for f in rtl_files)
        cmd = (
            f"iverilog -g2012 -Wall -s {self.flow.top} "
            f"-I {self.flow.src_dir} "
            f"-f {cmds_f} "
            f"-o {vvp_out} "
            f"{src_list} "
            f"> {log} 2>&1"
        )
        ok = self.flow.run_logged(cmd, log, f"UVM iverilog compile ({self.flow.top})")
        if not ok:
            print(f"       iverilog log → {log}")
        return ok

    def _run_test_file(self, test_file: Path) -> UVMRunSummary:
        module   = test_file.stem          # e.g.  test_directed
        xml_out  = self.build_dir / f"results_{module}.xml"
        vvp_out  = self.build_dir / "sim.vvp"
        log      = self.flow.log_dir / f"uvm_{module}_{self.flow.top}.log"

        lib_dir, lib_name = self._cocotb_libs()
        pythonpath        = self._build_pythonpath()

        env = os.environ.copy()
        env["COCOTB_TEST_MODULES"]  = module
        env["COCOTB_TOPLEVEL"]      = self.flow.top
        env["TOPLEVEL_LANG"]        = "verilog"
        env["COCOTB_RESULTS_FILE"]  = str(xml_out)
        env["PYGPI_PYTHON_BIN"]     = str(self.python)   # GPI C++ library reads this
        env["PYTHONPATH"]           = pythonpath
        env["LIBPYTHON_LOC"]        = self._libpython()

        cmd = f"vvp -M {lib_dir} -m {lib_name} {vvp_out} -none"

        with open(log, "w") as fh:
            proc = subprocess.run(
                cmd, shell=True, env=env,
                stdout=fh, stderr=subprocess.STDOUT,
                cwd=str(self.tests_dir),   # cwd = tests dir so relative imports work
            )

        result = self._parse_xml(xml_out, module)

        icon = "✓" if result.all_passed else "✗"
        color_fn = lambda s: s   # simple stdout; pillar adds color later
        for td in result.details:
            status_str = f"[{td.status}]"
            print(f"         {icon} {td.name}: {status_str}")

        if proc.returncode != 0 and result.total == 0:
            result.errors += 1
            result.details.append(UVMTestResult(module, "ERROR", f"vvp exit {proc.returncode}"))
            print(f"       UVM log → {log}")

        return result

    def _parse_xml(self, xml_path: Path, module: str) -> UVMRunSummary:
        summary = UVMRunSummary()
        if not xml_path.exists():
            summary.errors = 1
            summary.details.append(UVMTestResult(module, "ERROR", "no results.xml generated"))
            return summary

        try:
            tree = ET.parse(xml_path)
            root = tree.getroot()
        except ET.ParseError as e:
            summary.errors = 1
            summary.details.append(UVMTestResult(module, "ERROR", str(e)))
            return summary

        for tc in root.iter("testcase"):
            name = tc.get("name", tc.get("classname", module))
            failures = tc.findall("failure") + tc.findall("error")
            skipped  = tc.findall("skipped")

            if skipped:
                summary.skipped += 1
                summary.details.append(UVMTestResult(name, "SKIP"))
            elif failures:
                msg = failures[0].get("message", "")[:120]
                summary.failed += 1
                summary.details.append(UVMTestResult(name, "FAIL", msg))
            else:
                summary.passed += 1
                summary.details.append(UVMTestResult(name, "PASS"))

        return summary

    def _cocotb_libs(self):
        lib_dir  = subprocess.check_output(
            [str(self.python), "-m", "cocotb_tools.config", "--lib-dir"],
            text=True).strip()
        lib_name = subprocess.check_output(
            [str(self.python), "-m", "cocotb_tools.config", "--lib-name", "vpi", "icarus"],
            text=True).strip()
        return lib_dir, lib_name

    def _libpython(self) -> str:
        out = subprocess.check_output(
            [str(self.python), "-m", "cocotb_tools.config", "--libpython"],
            text=True).strip()
        return out

    def _build_pythonpath(self) -> str:
        site_pkgs = self.venv_bin.parent / "lib"
        site_dirs = sorted(site_pkgs.glob("python3*/site-packages"))
        parts = [
            str(self.uvm_dir),          # IP-specific components (fpu_driver etc.)
            str(self.tests_dir),        # test_*.py lives here
        ]
        parts += [str(d) for d in site_dirs]
        existing = os.environ.get("PYTHONPATH", "")
        if existing:
            parts.append(existing)
        return ":".join(parts)
