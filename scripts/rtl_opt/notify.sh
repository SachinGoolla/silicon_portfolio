#!/usr/bin/env bash
# notify.sh — fire a single notification so a human only engages at the end.
# Pick ONE channel. ntfy.sh is the zero-setup default (free, no account).
set -euo pipefail
MSG="${1:-FPU loop event}"

# Option A: ntfy.sh (subscribe to the topic on your phone app)
curl -s -d "$MSG" "https://ntfy.sh/fpu-loop-dada-ser" >/dev/null || true

# Option B: Slack incoming webhook — uncomment + set URL
# curl -s -X POST -H 'Content-type: application/json' \
#   --data "{\"text\":\"$MSG\"}" "$SLACK_WEBHOOK_URL" >/dev/null || true

echo "notified: $MSG"
