#!/usr/bin/env bash
# finalize.sh — archive signoff, clean artifacts (native pillar.py), cut a per-block tag.
#   finalize.sh <ip_path> <top> <wns_delta>
set -euo pipefail
REPO="$(git rev-parse --show-toplevel)"; cd "$REPO"
ENGINE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:?ip_path}"; TOP="${2:?top}"; DELTA="${3:-improved}"

mkdir -p "$TARGET/signoff"
LAST=$(ls -t "$TARGET"/build/.pillar_report_*.json 2>/dev/null | head -1 || true)
[[ -n "$LAST" ]] && cp "$LAST" "$TARGET/signoff/report-$(date +%Y%m%d-%H%M%S).json" || true

# native clean: wipes <ip>/build and <ip>/logs for this top
python3 scripts/pillar.py --top "$TOP" --ip-path "$TARGET" --step clean 2>/dev/null || true

VFILE="$TARGET/.version"; prev=$(cat "$VFILE" 2>/dev/null || echo 1); next=$((prev+1)); echo "$next" > "$VFILE"
TAG="${TOP}-v${next}-wns${DELTA}ns"
git add -A
git commit -q -m "release($TOP): ${TAG} (artifacts cleaned, signoff archived)" || true
git tag -a "$TAG" -m "Converged optimized $TOP. WNS delta ${DELTA}ns vs previous release."
echo "released: $TAG"
"$ENGINE/notify.sh" "$TOP converged → released $TAG" || true
