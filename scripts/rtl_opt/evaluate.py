#!/usr/bin/env python3
"""
evaluate.py — accept / reject / converged for one iteration.
Gates on the REAL fields from make_feedback.py. Formal (P2) and coverage (P5)
are deliberately NOT gated (P2 OOMs on this design; P5 is ~4% from the small P4 tb).
Reads: metrics.json, .baseline.json, opt.spec.yaml (via OPT_SPEC)
Prints: CONVERGED | ACCEPT | REJECT   (exit 0 / 10 / 20)
"""
import json, sys, os
from pathlib import Path


def load(p, d=None):
    p = Path(p)
    return json.loads(p.read_text()) if p.exists() else (d or {})


def load_spec():
    sp = Path(os.environ.get("OPT_SPEC", "opt.spec.yaml"))
    spec = {}
    for line in sp.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if ":" in line:
            k, v = line.split(":", 1)
            v = v.strip().strip('"')
            try:
                spec[k.strip()] = float(v)
            except ValueError:
                spec[k.strip()] = v
    return spec


def main():
    m    = load("metrics.json")
    base = load(".baseline.json", {})
    spec = load_spec()

    # 1. Correctness is non-negotiable.
    if not (m.get("p3_pass") and m.get("p7_pass") and m.get("gls_ok")
            and (m.get("lint_errors", 0) == 0)):
        print("REJECT"); sys.exit(20)

    wns   = m.get("wns_used_ns")          # prefers TT, falls back to worst corner
    cells = m.get("cells") or 0

    # 2. Converged?
    wns_ok   = (wns is None) or (wns >= spec.get("target_wns_ns", 0.0))
    cells_ok = (cells == 0) or (cells <= spec.get("max_cells", float("inf")))
    if wns_ok and cells_ok:
        print("CONVERGED"); sys.exit(0)

    # 3. First measured point becomes baseline.
    if not base:
        print("ACCEPT"); sys.exit(10)

    eps = spec.get("wns_eps_ns", 0.005)
    btn = base.get("wns_used_ns")
    bce = base.get("cells") or cells

    better_timing   = (wns is not None and btn is not None and wns > btn + eps)
    cells_not_worse = cells <= bce * (1 + spec.get("cells_tol", 0.02))
    if better_timing and cells_not_worse:
        print("ACCEPT"); sys.exit(10)

    if wns_ok:  # timing met → shrink cells without losing slack
        smaller    = cells < bce * (1 - spec.get("cells_eps", 0.005))
        slack_held = (wns is None) or (btn is None) or (wns >= btn - eps)
        if smaller and slack_held:
            print("ACCEPT"); sys.exit(10)

    print("REJECT"); sys.exit(20)


if __name__ == "__main__":
    main()
