#!/usr/bin/env python3
"""
make_feedback.py — compact the REAL silicon_portfolio flow output into a tiny packet.

Sources (per block, under <ip_dir>/build and <ip_dir>/logs):
  - .pillar_result_<step>.json   each pillar's own snapshot (authoritative for that pillar)
  - .pillar_report_*.json        merged report (used only as fallback)
  - logs/sta_<top>_*tt*.log      TT-corner OpenSTA log → TT worst slack + critical path
                                 (the report stores ONLY the worst corner, usually SS)

The LLM never sees raw logs — only feedback.json. That is the anti-hallucination line.

Env (set by optimize.sh):
  OPT_TARGET = ip path, e.g. ip_digital/fpu/fpu_top
  OPT_TOP    = top module, e.g. fpu_top
Outputs at repo root: feedback.json (for optimizer) + metrics.json (for evaluate.py)
"""
import json, re, os, glob, subprocess
from pathlib import Path


def repo_root() -> Path:
    try:
        r = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True).stdout.strip()
        if r:
            return Path(r)
    except Exception:
        pass
    return Path.cwd()


ROOT   = repo_root()
TARGET = os.environ.get("OPT_TARGET", "").strip("/")
TOP    = os.environ.get("OPT_TOP", Path(TARGET).name if TARGET else "")
IP_DIR = ROOT / TARGET
BUILD  = IP_DIR / "build"
LOGS   = IP_DIR / "logs"


def pillar_slice(step: str) -> dict:
    """Return the <step> metrics block from that step's own result file (preferred),
    else from the newest merged report."""
    rf = BUILD / f".pillar_result_{step}.json"
    if rf.exists():
        try:
            return json.loads(rf.read_text()).get("metrics", {}).get(step, {})
        except Exception:
            pass
    reps = sorted(BUILD.glob(".pillar_report_*.json"))
    if reps:
        try:
            return json.loads(reps[-1].read_text()).get(step, {})
        except Exception:
            pass
    return {}


def tt_log() -> Path | None:
    c = sorted(LOGS.glob(f"sta_{TOP}_*tt*.log")) or sorted(LOGS.glob(f"sta_{TOP}_*.log"))
    return c[0] if c else None


def tt_worst_path(log: Path | None):
    """(slack_ns, startpoint, endpoint, block_text) for worst TT setup path."""
    if not log or not log.exists():
        return (None, "", "", "")
    txt = log.read_text(errors="replace")
    worst = (None, "", "", "")
    for m in re.finditer(
        r"Startpoint:\s*(\S+).*?Endpoint:\s*(\S+).*?([+-]?[0-9]*\.?[0-9]+)\s+slack\s*\(\s*(?:MET|VIOLATED)\s*\)",
        txt, re.S | re.I):
        s = float(m.group(3))
        if worst[0] is None or s < worst[0]:
            worst = (s, m.group(1), m.group(2), m.group(0))
    if worst[0] is None:
        slks = [float(x) for x, _ in re.findall(
            r"([+-]?[0-9]*\.?[0-9]+)\s+slack\s*\(\s*(MET|VIOLATED)\s*\)", txt, re.I)]
        if slks:
            worst = (min(slks), "", "", "")
    return worst


def summarize_path(block: str):
    """From a report_checks path block, return (stage_count, top_cell_types)."""
    cells = re.findall(r"\(sky130_fd_sc_hd__(\w+)\)", block)
    if not cells:
        return 0, []
    from collections import Counter
    top = Counter(cells).most_common(4)
    return len(cells), [f"{name}×{n}" for name, n in top]


def endpoint_to_file(endpoint: str) -> str:
    """Map a path endpoint to its .sv file. Prefer THIS block's rtl/, then broaden."""
    roots = [IP_DIR / "rtl"] + [p for p in ROOT.glob("ip_digital/**/rtl") if p != IP_DIR / "rtl"]
    rtl = []
    for r in roots:
        rtl += sorted(r.glob("*.sv")) + sorted(r.glob("*.v"))
    toks = [t for t in re.split(r"[^A-Za-z0-9_]+", endpoint) if len(t) > 2]
    for tok in sorted(toks, key=len, reverse=True):
        for f in rtl:
            if tok.lower() in f.stem.lower() or f.stem.lower() in tok.lower():
                return str(f.relative_to(ROOT))
    own = sorted((IP_DIR / "rtl").glob(f"{TOP}*.sv"))
    return str(own[0].relative_to(ROOT)) if own else ""


def main():
    sta  = pillar_slice("sta")
    syn  = pillar_slice("synth")
    cov  = pillar_slice("coverage")
    fun  = pillar_slice("functional")
    lec  = pillar_slice("lec")
    lint = pillar_slice("lint")

    tt_slack, start, end, block = tt_worst_path(tt_log())
    stage_count, dominant_cells = summarize_path(block)
    worst_report = sta.get("slack_ns")            # worst corner from report (usually SS)
    wns = tt_slack if tt_slack is not None else worst_report
    slack_src = "TT(log)" if tt_slack is not None else "worst(report)"
    target_file = endpoint_to_file(end) if end else endpoint_to_file(TOP)

    metrics = {
        "wns_tt_ns":     tt_slack,                # None if TT log not found yet
        "wns_worst_ns":  worst_report,            # SS / worst corner from report
        "wns_used_ns":   wns,                      # what evaluate.py gates on
        "wns_source":    slack_src,
        "cells":         syn.get("total_cells", sta.get("total_cells")),
        "line_cov_pct":  cov.get("line_coverage_pct"),
        "toggle_cov_pct":cov.get("toggle_coverage_pct"),
        # hard invariants (formal P2 + coverage P5 intentionally NOT gated: OOM / 4%)
        "p3_pass":   fun.get("tests_failed", 1) == 0 and fun.get("tests_total", 0) > 0,
        "p7_pass":   lec.get("status") == "PASS" and lec.get("failed_points", 1) == 0,
        "gls_ok":    sta.get("gls_status") in ("PASS", "SKIP", "WARN"),  # only FAIL blocks
        "lint_errors": lint.get("errors", 0),
    }

    feedback = {
        "design": TARGET,
        "spec_limiting_metric": "wns_tt_ns" if (wns is not None and wns < 0) else "cells",
        "critical_path": {
            "slack_ns": wns,
            "slack_source": slack_src,
            "startpoint": start,
            "endpoint": end,
            "file": target_file,
            "logic_stages": stage_count,
            "dominant_cells": dominant_cells,
        },
        "hard_invariants_ok": bool(metrics["p3_pass"] and metrics["p7_pass"]
                                   and metrics["gls_ok"] and metrics["lint_errors"] == 0),
        "metrics": metrics,
        "note": ("Edit ONLY critical_path.file (an ip_digital/<block>/rtl/ source). "
                 "One change. Must stay LEC-equivalent (P7) and keep P3 + GLS passing. "
                 "Target the TT critical path; SS corner is advisory."),
    }

    (ROOT / "feedback.json").write_text(json.dumps(feedback, indent=2))
    (ROOT / "metrics.json").write_text(json.dumps(metrics, indent=2))
    print(json.dumps(feedback, indent=2))


if __name__ == "__main__":
    main()
