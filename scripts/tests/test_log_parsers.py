"""Regression tests for scripts/pillars/common.py log parsers.

Each test here traces back to a real bug found in this flow (see project
memory feedback_formal_sby) — these are not generic parser tests, they
pin the specific behaviors that broke in production.
"""
from pathlib import Path

from pillars.common import (
    FormalLogParser, LintLogParser, SimLogParser, STALogParser,
    decode_subprocess_output,
)


def _write(tmp_path: Path, name: str, content: str) -> Path:
    p = tmp_path / name
    p.write_text(content)
    return p


# ── FormalLogParser ─────────────────────────────────────────────────────────

def test_formal_parser_pass(tmp_path):
    log = _write(tmp_path, "f.log", "DONE (PASS, rc=0)\nsmtbmc z3\nk-induction\n")
    m = FormalLogParser(log).parse()
    assert m.status == "PASS"


def test_formal_parser_fail_on_counterexample(tmp_path):
    log = _write(tmp_path, "f.log", "DONE (FAIL, rc=2)\nsmtbmc z3\n")
    m = FormalLogParser(log).parse()
    assert m.status == "FAIL"


def test_formal_parser_solver_timeout_is_warn_not_pass(tmp_path):
    """The WARN->PASS bug: parse() used to have no WARN branch at all, so a
    solver that crashed mid-proof (no DONE line of any kind, just the z3
    BrokenPipeError text) fell through every `if`/`elif` and hit the
    unconditional `return "PASS"` at the bottom. A timeout/crash is not a
    disproven property, but it is absolutely not a proof either."""
    log = _write(tmp_path, "f.log",
                 "smtbmc z3\nstep 3..\n"
                 "z3 did not return a status for query process\n")
    m = FormalLogParser(log).parse()
    assert m.status == "WARN"
    assert m.status != "PASS"


def test_formal_parser_compile_error_is_fail_not_warn(tmp_path):
    """A real bug found while adding rr_arbiter's liveness property: sby's
    own summary line for a hard compile/syntax error ALSO says "did not
    return a status" (the engine never got to run at all), because that
    phrase is unconditional boilerplate in the summary, not evidence of a
    solver timeout. This is the exact log sby produced for a genuine
    rr_arbiter.sv syntax error -- a "<task>: task failed. ERROR." line for
    a setup-stage task (base/prep/smt2_*) must win over timed_out."""
    log = _write(tmp_path, "f.log",
                 "base: rr_arbiter.sv:141: ERROR: syntax error, unexpected '@'\n"
                 "base: finished (returncode=1)\n"
                 "base: task failed. ERROR.\n"
                 "summary: engine_0 (smtbmc --stbv z3) did not return a status\n"
                 "summary: engine_0 did not produce any traces\n"
                 "DONE (ERROR, rc=16)\n")
    m = FormalLogParser(log).parse()
    assert m.status == "FAIL"


def test_formal_parser_solver_crash_after_clean_compile_stays_warn(tmp_path):
    """The flip side of the compile-error fix above, using an actually
    captured log (rr_arbiter's liveness proof: z3 gave "Unexpected EOF
    response from solver" 2m25s in, after base/prep/smt2_stbv all finished
    with returncode=0). No "task failed. ERROR." line exists here -- only
    "ERROR: engine_N: Engine terminated without status." A solver crashing
    mid-proof after a clean compile is exactly the resource-crash case
    this repo's WARN classification exists for (see
    feedback_formal_sby) -- it must NOT be swept into FAIL just because
    DONE (ERROR) also appears here."""
    log = _write(tmp_path, "f.log",
                 "base: finished (returncode=0)\n"
                 "prep: finished (returncode=0)\n"
                 "smt2_stbv: finished (returncode=0)\n"
                 "engine_0.basecase: ##   0:01:00  waiting for solver (1 minute)\n"
                 "engine_0.induction: ##   0:02:25  Unexpected EOF response from solver.\n"
                 "engine_0.induction: finished (returncode=1)\n"
                 "ERROR: engine_0: Engine terminated without status.\n"
                 "engine_0.basecase: terminating process\n"
                 "summary: engine_0 (smtbmc --stbv z3) did not return a status\n"
                 "summary: engine_0 did not produce any traces\n"
                 "DONE (ERROR, rc=16)\n")
    m = FormalLogParser(log).parse()
    assert m.status == "WARN"


def test_formal_parser_no_done_line_and_no_timeout_stays_unknown(tmp_path):
    log = _write(tmp_path, "f.log", "smtbmc z3\nreading design..\n")
    m = FormalLogParser(log).parse()
    assert m.status == "UNKNOWN"


def test_formal_parser_max_step(tmp_path):
    log = _write(tmp_path, "f.log",
                 "DONE (PASS, rc=0)\nstep 0..\nstep 1..\nstep 9..\n")
    m = FormalLogParser(log).parse()
    assert m.max_step == 9


def test_formal_parser_induction_status(tmp_path):
    log = _write(tmp_path, "f.log",
                 "DONE (PASS, rc=0)\nTemporal induction successful.\n")
    m = FormalLogParser(log).parse()
    assert m.induction_status == "PASS"


# ── LintLogParser ────────────────────────────────────────────────────────────

def test_lint_parser_counts_warnings_and_errors(tmp_path):
    log = _write(tmp_path, "lint.log",
                 "%Warning-WIDTH: foo\n%Warning-UNUSED: bar\n%Error: baz\n")
    m = LintLogParser(log).parse()
    assert m.warnings == 2
    assert m.errors == 1


def test_lint_parser_empty_log_is_zero_not_crash(tmp_path):
    log = tmp_path / "missing.log"  # never written -> LogParser.content == ""
    m = LintLogParser(log).parse()
    assert m.warnings == 0
    assert m.errors == 0


# ── SimLogParser ─────────────────────────────────────────────────────────────

def test_sim_parser_fatal_is_fail_even_if_finish_also_present(tmp_path):
    """A design that hits $error mid-run but still reaches $finish (e.g. an
    assertion failure that doesn't halt simulation) must still FAIL — the
    fatal check has to win over the finished check."""
    log = _write(tmp_path, "sim.log", "%Error-ASSERT: mismatch\n$finish\n")
    m = SimLogParser(log).parse()
    assert m.status == "FAIL"


def test_sim_parser_clean_finish_is_pass(tmp_path):
    log = _write(tmp_path, "sim.log", "run complete\n$finish\n")
    m = SimLogParser(log).parse()
    assert m.status == "PASS"


def test_sim_parser_no_finish_no_fatal_is_unknown(tmp_path):
    log = _write(tmp_path, "sim.log", "still running...\n")
    m = SimLogParser(log).parse()
    assert m.status == "UNKNOWN"


# ── STALogParser ─────────────────────────────────────────────────────────────

def test_sta_parser_picks_worst_slack_across_all_endpoints(tmp_path):
    log = _write(tmp_path, "sta.log",
                 "  -0.431   slack (VIOLATED)\n"
                 "  2.100   slack (MET)\n"
                 "  -84.202   slack (VIOLATED)\n")
    m = STALogParser(log).parse()
    assert m.slack_ns == -84.202
    assert m.slack_status == "VIOLATED"
    assert m.timing_violations == 2


def test_sta_parser_all_met_reports_met(tmp_path):
    log = _write(tmp_path, "sta.log", "  1.5   slack (MET)\n  0.2   slack (MET)\n")
    m = STALogParser(log).parse()
    assert m.slack_status == "MET"
    assert m.timing_violations == 0


# ── decode_subprocess_output ────────────────────────────────────────────────

def test_decode_subprocess_output_bytes():
    """TimeoutExpired.stdout/.stderr can be raw bytes even under text=True —
    naively doing `(e.stdout or "") + "..."` raises TypeError and silently
    breaks the except-handler that was supposed to log the timeout."""
    assert decode_subprocess_output(b"hello z3") == "hello z3"


def test_decode_subprocess_output_str_passthrough():
    assert decode_subprocess_output("already text") == "already text"


def test_decode_subprocess_output_none_is_empty_string():
    assert decode_subprocess_output(None) == ""


def test_decode_subprocess_output_can_concat_with_str():
    combined = decode_subprocess_output(b"partial output") + " ...(truncated)"
    assert combined == "partial output ...(truncated)"
