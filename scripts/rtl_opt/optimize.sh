#!/usr/bin/env bash
# optimize.sh — deterministic, REUSABLE RTL optimization loop for the
# silicon_portfolio pillar flow. Works on ANY ip_digital block.
#
#   ./scripts/rtl_opt/optimize.sh ip_digital/alu/fpu_top
#
# The block's opt.spec.yaml supplies top, ip_path, flow_cmd, targets, budgets.
# The LOOP is shell (0 tokens). The only LLM call per iteration is a fresh
# `claude -p` seeing CLAUDE.md + feedback.json + 1 file, so context never grows.
set -uo pipefail

TARGET="${1:?usage: optimize.sh <ip_path, e.g. ip_digital/alu/fpu_top>}"
REPO="$(git rev-parse --show-toplevel)"; cd "$REPO"
ENGINE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${TARGET%/}"
SPEC="$TARGET/opt.spec.yaml"
[[ -f "$SPEC" ]] || { echo "missing $SPEC — copy the opt.spec.yaml template into the block"; exit 1; }

read_spec() { grep -E "^$1:" "$SPEC" | head -1 | sed -E "s/^$1:[[:space:]]*//; s/[[:space:]]*#.*//; s/^\"//; s/\"$//"; }
TOP="$(read_spec top)"
FLOW="$(read_spec flow_cmd)"
MAX_ITERS=$(read_spec max_iters); MAX_REJ=$(read_spec max_rejects); MAX_WALL=$(read_spec max_wall_min)
[[ -n "$FLOW" && -n "$TOP" ]] || { echo "set top: and flow_cmd: in $SPEC"; exit 1; }

export OPT_TARGET="$TARGET" OPT_TOP="$TOP" OPT_SPEC="$SPEC"
RUN_BRANCH="opt/${TOP}-$(date +%Y%m%d-%H%M%S)"
START=$(date +%s)

git checkout -b "$RUN_BRANCH" || git checkout "$RUN_BRANCH"
echo "=== $TOP ($TARGET) on $RUN_BRANCH | budgets: iters=$MAX_ITERS rejects=$MAX_REJ wall=${MAX_WALL}m ==="

# --- baseline: measure current RTL once (the flow re-runs only changed pillars) ---
eval "$FLOW" >/dev/null 2>&1
python3 "$ENGINE/make_feedback.py" >/dev/null
cp metrics.json .baseline.json
echo "baseline: $(cat .baseline.json)"

rejects=0
for ((i=1; i<=MAX_ITERS; i++)); do
  elapsed_min=$(( ($(date +%s) - START) / 60 ))
  (( elapsed_min >= MAX_WALL )) && { echo "STOP: wall-clock budget hit"; break; }
  (( rejects   >= MAX_REJ   )) && { echo "STOP: $rejects consecutive rejects (stuck)"; break; }
  echo "--- iter $i (rejects=$rejects, ${elapsed_min}m) ---"

  SNAP=$(git rev-parse HEAD)   # snapshot for atomic rollback of a bad edit

  # === the single LLM touch-point: fresh, tiny context, headless ===
  claude -p "Read feedback.json. Use @log-triage to pick the target, then @rtl-optimizer to apply exactly one safe, LEC-equivalent edit to that file. Do not run the flow. Stop after the edit." \
         --permission-mode acceptEdits --max-turns 8 --output-format text >/dev/null 2>&1

  eval "$FLOW" >/dev/null 2>&1                 # re-verify (changed pillars re-run on hash change)
  python3 "$ENGINE/make_feedback.py" >/dev/null

  set +e; verdict=$(python3 "$ENGINE/evaluate.py"); rc=$?; set -e
  echo "verdict: $verdict"

  case "$rc" in
    0)  # CONVERGED
        d_wns=$(python3 -c "import json;b=json.load(open('.baseline.json'));m=json.load(open('metrics.json'));print(f\"{(m['wns_used_ns'] or 0)-(b['wns_used_ns'] or 0):+.3f}\")")
        git add -A "$TARGET" && git commit -q -m "opt($TOP): CONVERGED wns ${d_wns}ns (iter $i)"
        "$ENGINE/finalize.sh" "$TARGET" "$TOP" "$d_wns"
        echo "=== CONVERGED: $TOP at iter $i ==="; exit 0 ;;
    10) # ACCEPT
        d=$(python3 -c "import json;b=json.load(open('.baseline.json'));m=json.load(open('metrics.json'));print(f\"wns {(m['wns_used_ns'] or 0)-(b['wns_used_ns'] or 0):+.3f}ns cells {(m.get('cells') or 0)-(b.get('cells') or 0):+d}\")")
        git add -A "$TARGET" && git commit -q -m "opt($TOP): accept $d (iter $i)"
        cp metrics.json .baseline.json
        echo "- iter $i: $d :: $(python3 -c "import json;print(json.load(open('feedback.json'))['critical_path']['file'])")" >> "$TARGET/learned_skills.md"
        rejects=0 ;;
    20) # REJECT — roll only this block's files back
        git checkout -q "$SNAP" -- "$TARGET"
        rejects=$((rejects+1)) ;;
  esac
done

echo "=== loop ended without convergence for $TOP (best on $RUN_BRANCH) ==="
"$ENGINE/notify.sh" "rtl-opt: $TOP ended on $RUN_BRANCH after $i iters, no convergence" || true
exit 1
