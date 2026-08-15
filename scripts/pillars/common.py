"""Shared infrastructure: colors, dataclasses, log parsers, Dashboard."""
import os
import re
import signal
import subprocess
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple


def run_with_timeout(cmd: str, timeout: float, **kwargs) -> subprocess.CompletedProcess:
    """Drop-in replacement for `subprocess.run(cmd, shell=True, timeout=...)`
    that actually kills the whole process tree when the timeout fires.

    `subprocess.run(..., timeout=N)` only sends the kill signal to the
    immediate child — with `shell=True` that child is the shell itself
    (`/bin/sh -c "..."`), not the real workload. A chain like
    `sh -c "sby -f x.sby"` → `sby` → `yosys-smtbmc` → `z3` means the shell
    dying does NOT kill `z3`: it gets reparented to init and keeps running,
    still holding its RAM, invisible to the caller who believes the timeout
    "worked". This was directly observed and root-caused during a session
    where orphaned z3 processes survived 6-39 minutes past their supposed
    timeout, compounding with later pillar steps and once crashing the
    whole machine via OOM (see project memory feedback-resource-limits).

    Fix: launch in a new process group (`start_new_session=True`) and on
    timeout, SIGKILL the entire group (`os.killpg`), not just the shell.

    Mirrors `subprocess.run`'s contract: returns CompletedProcess, raises
    `subprocess.TimeoutExpired` (with whatever partial output was captured)
    on timeout and `subprocess.CalledProcessError` on a nonzero exit when
    `check=True` — existing except-handlers written against `subprocess.run`
    work unchanged against this function.
    """
    if kwargs.pop('capture_output', False):
        kwargs.setdefault('stdout', subprocess.PIPE)
        kwargs.setdefault('stderr', subprocess.PIPE)
    check = kwargs.pop('check', False)

    proc = subprocess.Popen(cmd, shell=True, start_new_session=True, **kwargs)
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass  # already gone
        try:
            stdout, stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            stdout, stderr = None, None
        raise subprocess.TimeoutExpired(cmd, timeout, output=stdout, stderr=stderr)

    if check and proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd, stdout, stderr)
    return subprocess.CompletedProcess(cmd, proc.returncode, stdout, stderr)


def decode_subprocess_output(x) -> str:
    """Safely turn subprocess output into str.

    subprocess.TimeoutExpired.stdout/.stderr can be raw bytes even when the
    original subprocess.run() call passed text=True — the exception is
    raised from inside Popen.communicate() before its text-decode step
    runs, so the exception object still holds undecoded bytes. Naively
    concatenating that with a str literal raises TypeError and silently
    breaks the except-handler that was supposed to log the timeout.
    """
    if x is None:
        return ""
    if isinstance(x, bytes):
        return x.decode("utf-8", errors="replace")
    return x


# ── ANSI palette ──────────────────────────────────────────────────────────────

class C:
    RESET = "\033[0m"; BOLD = "\033[1m"; DIM = "\033[2m"
    RED = "\033[31m"; GREEN = "\033[32m"; YELLOW = "\033[33m"
    BLUE = "\033[34m"; MAGENTA = "\033[35m"; CYAN = "\033[36m"
    BRED = "\033[91m"; BGREEN = "\033[92m"; BYELLOW = "\033[93m"
    BBLUE = "\033[94m"; BMAGENTA = "\033[95m"; BCYAN = "\033[96m"; BWHITE = "\033[97m"

    @staticmethod
    def ok(s):   return f"{C.BGREEN}{s}{C.RESET}"
    @staticmethod
    def warn(s): return f"{C.BYELLOW}{s}{C.RESET}"
    @staticmethod
    def err(s):  return f"{C.BRED}{s}{C.RESET}"
    @staticmethod
    def info(s): return f"{C.BCYAN}{s}{C.RESET}"
    @staticmethod
    def hdr(s):  return f"{C.BOLD}{C.BBLUE}{s}{C.RESET}"
    @staticmethod
    def dim(s):  return f"{C.DIM}{s}{C.RESET}"
    @staticmethod
    def hi(s):   return f"{C.BMAGENTA}{s}{C.RESET}"


PILLAR_ICONS = ["🔍", "🔬", "✅", "🎬", "📈", "🏗️", "⚖️", "⏱️"]
PILLAR_NAMES = ["Lint+CDC", "Formal", "Functional", "Simulation", "Coverage",
                "Synthesis", "LEC", "STA+GLS"]


# ── Dataclasses ───────────────────────────────────────────────────────────────

@dataclass
class LintMetrics:
    warnings: int = 0; errors: int = 0; wall_time: float = 0
    cpu_time: float = 0; memory_mb: float = 0; modules: int = 0
    elaboration_time: float = 0; conversion_time: float = 0; build_time: float = 0
    warning_details: List[str] = field(default_factory=list)

@dataclass
class FormalMetrics:
    status: str = "UNKNOWN"; depth: int = 0; max_step: int = 0
    solver: str = "UNKNOWN"; wall_time: float = 0
    basecase_status: str = "UNKNOWN"; induction_status: str = "UNKNOWN"
    proof_method: str = "UNKNOWN"

@dataclass
class FunctionalMetrics:
    tests_total: int = 0; tests_passed: int = 0; tests_failed: int = 0
    tests_skipped: int = 0; sim_time_ns: float = 0; cpu_time_s: float = 0
    speed_ratio: float = 0; seed: str = "Unknown"
    test_details: List[Dict] = field(default_factory=list)
    # Optional: populated only when a pyuvm test's own report_phase() logs a
    # "coverage=NN.N%" line (e.g. mac_cluster's test_coverage_closure) --
    # None-tolerant, same idiom P5's CoverageMetrics uses for fields that
    # aren't always populated (e.g. when --coverage-expr wasn't run).
    func_cov_pct: float = None
    func_cov_bins: Dict[str, float] = field(default_factory=dict)

@dataclass
class SimMetrics:
    status: str = "UNKNOWN"; sim_end_time: str = "0"
    sim_speed_ns_per_s: float = 0; wall_time: float = 0
    cpu_time: float = 0; memory_mb: float = 0
    vcd_size_mb: float = 0; exe_size_mb: float = 0

@dataclass
class CoverageMetrics:
    line_coverage_pct: float = 0; branch_coverage_pct: float = 0
    toggle_coverage_pct: float = 0
    uncovered_lines: List[Tuple] = field(default_factory=list)
    total_lines_analyzed: int = 0

@dataclass
class SynthMetrics:
    status: str = "UNKNOWN"; total_cells: int = 0; total_wires: int = 0
    cell_breakdown: Dict[str, int] = field(default_factory=dict)

@dataclass
class LECMetrics:
    status: str = "UNKNOWN"; proven_points: int = 0; failed_points: int = 0
    error_msg: str = ""

@dataclass
class STAMetrics:
    total_cells: int = 0; cell_breakdown: Dict[str, int] = field(default_factory=dict)
    total_wires: int = 0; data_path_delay_ns: float = 0
    max_frequency_mhz: float = 0; slack_ns: float = 0
    slack_status: str = "UNKNOWN"; timing_violations: int = 0
    critical_paths: List[Dict] = field(default_factory=list)
    gls_status: str = "SKIP"

@dataclass
class AllPillarMetrics:
    timestamp: str; module_name: str
    lint: LintMetrics = field(default_factory=LintMetrics)
    formal: FormalMetrics = field(default_factory=FormalMetrics)
    functional: FunctionalMetrics = field(default_factory=FunctionalMetrics)
    sim: SimMetrics = field(default_factory=SimMetrics)
    coverage: CoverageMetrics = field(default_factory=CoverageMetrics)
    synth: SynthMetrics = field(default_factory=SynthMetrics)
    lec: LECMetrics = field(default_factory=LECMetrics)
    sta: STAMetrics = field(default_factory=STAMetrics)


# ── Log parsers ───────────────────────────────────────────────────────────────

class LogParser:
    def __init__(self, log_file: Path):
        self.log_file = log_file
        self.content = log_file.read_text(errors='replace') if log_file.exists() else ""

    def _num(self, pattern: str, group: int = 1) -> Optional[float]:
        m = re.search(pattern, self.content, re.IGNORECASE)
        try:
            return float(m.group(group)) if m else None
        except (ValueError, IndexError):
            return None

    def _str(self, pattern: str, group: int = 1) -> Optional[str]:
        m = re.search(pattern, self.content, re.IGNORECASE)
        return m.group(group) if m else None


class LintLogParser(LogParser):
    def parse(self) -> LintMetrics:
        m = LintMetrics()
        if not self.content:
            return m
        for line in self.content.splitlines():
            if '%Warning' in line:
                m.warnings += 1
                m.warning_details.append(line.strip())
            elif '%Error' in line:
                m.errors += 1
                m.warning_details.append(line.strip())
        m.warning_details = m.warning_details[:10]
        m.wall_time  = self._num(r'Walltime ([0-9.]+)\s*s') or 0
        m.cpu_time   = self._num(r'cpu ([0-9.]+)\s*s') or 0
        m.memory_mb  = self._num(r'alloced ([0-9.]+)\s*MB') or 0
        m.elaboration_time = self._num(r'elab=([0-9.]+)') or 0
        m.conversion_time  = self._num(r'cvt=([0-9.]+)') or 0
        m.build_time       = self._num(r'bld=([0-9.]+)') or 0
        return m


class FormalLogParser(LogParser):
    def parse(self) -> FormalMetrics:
        m = FormalMetrics()
        if not self.content:
            return m
        # Count tasks: sby may run multiple tasks; all must PASS for overall PASS.
        n_pass  = self.content.count("DONE (PASS")
        n_fail  = self.content.count("DONE (FAIL")
        n_error = self.content.count("DONE (ERROR")
        timed_out = "did not return a status" in self.content
        # A genuine compile/syntax error (sby's setup pipeline — `base`,
        # `prep`, `smt2_*` — failing to even parse/elaborate the design)
        # ALSO prints "engine_0 ... did not return a status" in its
        # summary, since the engine never got a chance to run at all. That
        # made compile errors indistinguishable from a real solver
        # timeout/crash by `timed_out` alone. The two ARE distinguishable
        # in the log: a compile failure prints "<task>: task failed.
        # ERROR." for one of the setup tasks; a solver crashing mid-proof
        # after successfully compiling (the case the WARN classification
        # exists for — see feedback_formal_sby) never prints that line, it
        # only prints "ERROR: engine_N: Engine terminated without status."
        # Confirmed against two real captured logs: a genuine rr_arbiter.sv
        # syntax error (has "base: task failed. ERROR.") vs. a genuine z3
        # EOF crash on rr_arbiter's liveness proof after a clean compile
        # (does not).
        compile_failed = bool(re.search(
            r'\b(?:base|prep|smt2\w*): task failed\. ERROR\.', self.content))
        if n_pass > 0 and n_fail == 0 and n_error == 0:
            m.status = "PASS"
        elif n_fail > 0:
            m.status = "FAIL"
        elif compile_failed:
            m.status = "FAIL"
        elif timed_out:
            m.status = "WARN"   # solver timeout ≠ counterexample; treat as advisory
        elif n_error > 0:
            m.status = "FAIL"
        steps = re.findall(r'step (\d+)\.\.', self.content)
        m.max_step = max(int(s) for s in steps) if steps else 0
        if "smtbmc z3" in self.content:     m.solver = "z3"
        elif "smtbmc boolector" in self.content: m.solver = "boolector"
        elif "smtbmc yices" in self.content: m.solver = "yices"
        if "Temporal induction successful" in self.content: m.induction_status = "PASS"
        elif "Temporal induction failed" in self.content:  m.induction_status = "FAIL"
        if "k-induction" in self.content:    m.proof_method = "k-induction"
        elif "bmc" in self.content.lower():  m.proof_method = "bounded-model-check"
        return m


class FunctionalLogParser(LogParser):
    def parse(self) -> FunctionalMetrics:
        m = FunctionalMetrics()
        if not self.content:
            return m
        ts = re.search(
            r'\*\*\s+TESTS=(\d+)\s+PASS=(\d+)\s+FAIL=(\d+)\s+SKIP=(\d+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)',
            self.content)
        if ts:
            m.tests_total, m.tests_passed, m.tests_failed, m.tests_skipped = (
                int(ts.group(1)), int(ts.group(2)), int(ts.group(3)), int(ts.group(4)))
            m.sim_time_ns = float(ts.group(5)); m.cpu_time_s = float(ts.group(6))
            m.speed_ratio = float(ts.group(7))
        sm = re.search(r'Seeding Python random module with (\d+)', self.content)
        if sm:
            m.seed = sm.group(1)
        for name, status, t in re.findall(r'\*\*\s+(\S+)\s+(\w+)\s+(\d+(?:\.\d+)?)', self.content):
            if status in ('PASS', 'FAIL', 'SKIP'):
                m.test_details.append({'name': name, 'status': status, 'sim_time_ns': float(t)})
        return m


class FunctionalXMLParser:
    def __init__(self, xml_file: Path):
        self.xml_file = xml_file

    def parse(self) -> FunctionalMetrics:
        m = FunctionalMetrics()
        if not self.xml_file.exists():
            return m
        try:
            root = ET.parse(self.xml_file).getroot()
            for tc in root.iter('testcase'):
                failed  = tc.find('failure') is not None or tc.find('error') is not None
                skipped = tc.find('skipped') is not None
                status  = 'FAIL' if failed else ('SKIP' if skipped else 'PASS')
                sim_ns  = float(tc.get('sim_time_ns', tc.get('time', 0)))
                m.tests_total += 1
                if failed:   m.tests_failed += 1
                elif skipped: m.tests_skipped += 1
                else:         m.tests_passed += 1
                m.test_details.append({'name': tc.get('name', '?'), 'status': status, 'sim_time_ns': sim_ns})
            for prop in root.iter('property'):
                if prop.get('name') == 'random_seed':
                    m.seed = prop.get('value', 'Unknown')
        except Exception:
            pass
        return m


class SimLogParser(LogParser):
    _FATAL = [r'\$fatal', r'\$error', r'%Error-ASSERT', r'Assertion failed', r'FAILED']

    def parse(self) -> SimMetrics:
        m = SimMetrics()
        if not self.content:
            return m
        finished = any(k in self.content for k in ('$finish', 'COMPLETE', 'PASS'))
        if any(re.search(p, self.content) for p in self._FATAL):
            m.status = "FAIL"
        elif finished:
            m.status = "PASS"
        m.wall_time = self._num(r'walltime ([0-9.]+)\s*s') or 0
        m.cpu_time  = self._num(r'cpu ([0-9.]+)\s*s') or 0
        m.memory_mb = self._num(r'alloced ([0-9.]+)\s*MB') or 0
        m.sim_speed_ns_per_s = self._num(r'speed ([0-9.]+)\s*ns/s') or 0
        fm = re.search(r'at ([0-9.]+)ps', self.content)
        if fm:
            m.sim_end_time = fm.group(1)
        return m


class SynthLogParser(LogParser):
    def parse(self) -> Tuple[int, int, Dict[str, int]]:
        # Yosys prints "Number of cells:"/"Number of wires:" once per
        # submodule during hierarchy-analysis/opt passes, then again in a
        # final rolled-up "=== design hierarchy ===" summary. A plain
        # re.search() grabs the FIRST (a small submodule's own count), not
        # the final flattened total. Anchor on the summary marker; fall back
        # to the last match anywhere in the log if the marker is absent.
        marker = self.content.rfind('=== design hierarchy ===')
        tail = self.content[marker:] if marker != -1 else self.content

        def _last_match(pattern: str, text: str) -> int:
            matches = re.findall(pattern, text)
            return int(matches[-1]) if matches else 0

        cells = _last_match(r'Number of cells:\s+(\d+)', tail)
        wires = _last_match(r'Number of wires:\s+(\d+)', tail)
        if cells == 0 and marker != -1:
            cells = _last_match(r'Number of cells:\s+(\d+)', self.content)
        if wires == 0 and marker != -1:
            wires = _last_match(r'Number of wires:\s+(\d+)', self.content)
        breakdown = {ct: int(cn) for ct, cn in
                     re.findall(r'^\s+(\S+)\s+(\d+)\s*$', tail, re.MULTILINE)}
        return cells, wires, breakdown


class STALogParser(LogParser):
    def parse(self) -> STAMetrics:
        m = STAMetrics()
        if not self.content:
            return m
        # Collect ALL path-endpoint slack values (format: "  -0.431   slack (VIOLATED)")
        # Use the explicit (MET)/(VIOLATED) form to avoid false positives
        all_slacks = re.findall(
            r'([+-]?[0-9]*\.?[0-9]+)\s+slack\s*\(\s*(MET|VIOLATED)\s*\)',
            self.content, re.IGNORECASE)
        if all_slacks:
            parsed = [(float(s), st.upper()) for s, st in all_slacks]
            worst = min(parsed, key=lambda x: x[0])
            m.slack_ns     = worst[0]
            m.slack_status = worst[1]
            m.timing_violations = sum(1 for _, st in parsed if st == 'VIOLATED')
        pm = re.search(r'([+-]?[0-9]*\.?[0-9]+)\s+clock\s+period', self.content, re.IGNORECASE)
        if pm:
            period = float(pm.group(1))
            if period > 0 and m.slack_ns != 0:
                min_p = period - m.slack_ns
                if min_p > 0:
                    m.max_frequency_mhz = 1000.0 / min_p
        dm = re.search(r'([+-]?[0-9]*\.?[0-9]+)\s+data arrival time', self.content, re.IGNORECASE)
        if dm:
            m.data_path_delay_ns = abs(float(dm.group(1)))
            if m.max_frequency_mhz == 0 and m.data_path_delay_ns > 0:
                m.max_frequency_mhz = 1000.0 / m.data_path_delay_ns
        return m


# ── Dashboard ─────────────────────────────────────────────────────────────────

class Dashboard:
    BOX_WIDTH = 56

    def __init__(self, title: str, color: str = C.BCYAN):
        self.title = title; self.color = color
        self.rows: list = []; self.insights: list = []

    def add_row(self, label: str, value: str, value_color: str = ""):
        self.rows.append(("row", label, value, value_color))

    def add_section_header(self, label: str = ""):
        self.rows.append(("sep", label))

    def add_metric(self, label: str, value, suffix: str = "", value_color: str = ""):
        self.add_row(label, str(value) + suffix, value_color)

    def add_insight(self, text: str, kind: str = "info"):
        """kind: 'good' | 'warn' | 'improve' | 'info'"""
        self.insights.append((kind, text))

    def _colored_status(self, val: str) -> str:
        if val in ("PASS", "MET", "✓"):   return C.ok(val)
        if val in ("FAIL", "VIOLATED", "✗"): return C.err(val)
        if val in ("UNKNOWN", "SKIP", "⚠"): return C.warn(val)
        return val

    def print(self):
        w = self.BOX_WIDTH
        title_line = f" {self.color}{C.BOLD}{self.title}{C.RESET} "
        vis_len = len(self.title) + 2
        pad = w - 4 - vis_len; lpad = pad // 2; rpad = pad - lpad
        print(f"  {C.DIM}╭{'─'*(w-2)}╮{C.RESET}")
        print(f"  {C.DIM}│{C.RESET}{' '*lpad}{title_line}{' '*rpad}{C.DIM}│{C.RESET}")
        print(f"  {C.DIM}├{'─'*(w-2)}┤{C.RESET}")
        for row in self.rows:
            if row[0] == "sep":
                label = row[1]
                if label:
                    inner = f" {C.DIM}{label}{C.RESET} "; vis = len(label)+2
                    dashes = w-2-vis; ld = dashes//2; rd = dashes-ld
                    print(f"  {C.DIM}├{'─'*ld}{C.RESET}{inner}{C.DIM}{'─'*rd}┤{C.RESET}")
                else:
                    print(f"  {C.DIM}├{'─'*(w-2)}┤{C.RESET}")
            else:
                _, label, value, vc = row
                colored_val = self._colored_status(value) if not vc else f"{vc}{value}{C.RESET}"
                raw_label = f"{label:<22}"; raw_value = value
                colored_line = f"{C.DIM}{raw_label}{C.RESET} {colored_val}"
                trailing = max(0, w - 4 - 22 - 1 - len(raw_value))
                print(f"  {C.DIM}│{C.RESET} {colored_line}{' '*trailing} {C.DIM}│{C.RESET}")
        print(f"  {C.DIM}╰{'─'*(w-2)}╯{C.RESET}")
        if self.insights:
            _KIND = {
                "good":    (C.BGREEN,  "✔"),
                "warn":    (C.BRED,    "✖"),
                "improve": (C.BYELLOW, "◆"),
                "info":    (C.BCYAN,   "•"),
            }
            print(f"  {C.BCYAN}┌─ Design Insights {'─'*(w-21)}┐{C.RESET}")
            for item in self.insights:
                kind, ins = item if isinstance(item, tuple) else ("info", item)
                clr, bullet = _KIND.get(kind, _KIND["info"])
                prefix = f"{clr}{bullet}{C.RESET} "
                words = ins.split(); line = ""; first = True
                for word in words:
                    if len(line) + len(word) + 1 > w - 8:
                        indent = prefix if first else "   "
                        print(f"  {C.BCYAN}│{C.RESET} {indent}{clr}{line}{C.RESET}")
                        line = word; first = False
                    else:
                        line = (line + " " + word).strip()
                if line:
                    indent = prefix if first else "   "
                    print(f"  {C.BCYAN}│{C.RESET} {indent}{clr}{line}{C.RESET}")
            print(f"  {C.BCYAN}└{'─'*(w-4)}┘{C.RESET}")

    @staticmethod
    def progress_bar(pct: int, length: int = 36) -> str:
        pct = max(0, min(100, pct))
        filled = int((pct / 100.0) * length)
        bar = '█' * filled + '─' * (length - filled)
        if pct == 100:  return f"{C.BGREEN}{bar}{C.RESET}"
        elif pct >= 80: return f"{C.BYELLOW}{bar}{C.RESET}"
        else:           return f"{C.BRED}{bar}{C.RESET}"
