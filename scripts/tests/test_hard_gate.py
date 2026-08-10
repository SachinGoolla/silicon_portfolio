"""Regression tests for pillar.py's hard-gate policy: FAIL always fails the
build; WARN fails it too unless _pillar_note() recognizes it as a known,
documented pattern. See pillar.py's _evaluate_hard_gate() docstring for the
motivating bug (undocumented WARN used to blend into "all pillars passed").
"""
from pillar import _evaluate_hard_gate, _pillar_note


# ── _pillar_note: documented-pattern lookup ─────────────────────────────────

def test_lec_sequential_warn_is_documented():
    assert _pillar_note("lec", "WARN", {}) is not None


def test_upf_skip_no_file_is_documented():
    assert _pillar_note("upf", "SKIP", {}) is not None


def test_formal_warn_solver_timeout_is_documented():
    assert _pillar_note("formal", "WARN", {}) is not None


def test_sta_pass_with_violated_ss_corner_is_documented():
    row = {"slack_status": "VIOLATED", "slack_ns": -84.202}
    assert _pillar_note("sta", "PASS", row) is not None


def test_sta_warn_status_is_not_documented():
    """The documented STA rationale is specifically for PASS+VIOLATED (TT
    met, SS advisory). An actual WARN status on STA is a different,
    unexplained situation and must not silently match this pattern."""
    row = {"slack_status": "VIOLATED", "slack_ns": -84.202}
    assert _pillar_note("sta", "WARN", row) is None


def test_unknown_pillar_warn_is_undocumented():
    assert _pillar_note("sim", "WARN", {}) is None
    assert _pillar_note("lint", "WARN", {}) is None
    assert _pillar_note("synth", "WARN", {}) is None


# ── _evaluate_hard_gate ──────────────────────────────────────────────────────

def test_all_pass_does_not_hard_fail():
    hard_fail, warns = _evaluate_hard_gate({"lint": "PASS", "sim": "PASS"}, {})
    assert hard_fail is False
    assert warns == []


def test_any_fail_hard_fails_regardless_of_others():
    hard_fail, warns = _evaluate_hard_gate(
        {"lint": "PASS", "functional": "FAIL", "sim": "PASS"}, {})
    assert hard_fail is True


def test_documented_warn_does_not_hard_fail():
    """This is the exact case that had to keep working: axi_lite_slave's LEC
    WARN (sequential LEC, RTL<->PDK state-encoding gap) is a known,
    documented limitation and must not block the build."""
    hard_fail, warns = _evaluate_hard_gate({"lec": "WARN", "synth": "PASS"}, {})
    assert hard_fail is False
    assert warns == []


def test_undocumented_warn_hard_fails():
    """A WARN on a pillar/status combo with no _pillar_note() rationale is
    either a new regression or an unexamined failure mode — must stop the
    build, not blend into 'all pillars passed or skipped'."""
    hard_fail, warns = _evaluate_hard_gate({"sim": "WARN", "lint": "PASS"}, {})
    assert hard_fail is True
    assert warns == ["sim"]


def test_skip_never_hard_fails():
    hard_fail, warns = _evaluate_hard_gate({"upf": "SKIP", "lint": "PASS"}, {})
    assert hard_fail is False
    assert warns == []


def test_mixed_documented_and_undocumented_warns_reports_only_undocumented():
    hard_fail, warns = _evaluate_hard_gate(
        {"lec": "WARN", "sim": "WARN", "lint": "PASS"}, {})
    assert hard_fail is True
    assert warns == ["sim"]


def test_fail_short_circuits_before_checking_warns():
    """When there's already a hard FAIL, undocumented_warns collection is
    skipped entirely (no need to explain WARNs when the build is already
    dead) -- the returned warn list should be empty, not misleading."""
    hard_fail, warns = _evaluate_hard_gate({"functional": "FAIL", "sim": "WARN"}, {})
    assert hard_fail is True
    assert warns == []
