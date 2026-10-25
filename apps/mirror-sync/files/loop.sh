#!/usr/bin/env bash
# Run sync.sh forever, once every INTERVAL seconds, in one long-lived pod. A pod that stays
# up avoids a new pod, image check and scheduling every minute. One process runs the loop,
# so two runs can never overlap.
#
# Inputs (environment): the inputs of sync.sh, and
#   INTERVAL      optional. Seconds from the start of one run to the start of the next. Default 60.
#   RUN_DEADLINE  optional. Seconds one run may take before it is killed. Default 900.
#   HEARTBEAT     optional. A file whose modified time the liveness probe reads. Default /tmp/heartbeat.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
interval="${INTERVAL:-60}"
deadline="${RUN_DEADLINE:-900}"
heartbeat="${HEARTBEAT:-/tmp/heartbeat}"

trap 'kill "${run:-}" 2>/dev/null; exit 0' TERM INT

while true; do
  started="$(date +%s)"
  # The run is a background job, so that SIGTERM stops the pod at once.
  timeout --kill-after=10 "$deadline" "$here/sync.sh" & run=$!
  wait "$run" || echo "loop: the run failed or timed out. The next run starts on schedule."
  touch "$heartbeat"
  wait_s=$((interval - ($(date +%s) - started)))
  # sleep runs in the background so that SIGTERM stops the pod at once.
  if [ "$wait_s" -gt 0 ]; then sleep "$wait_s" & wait $!; fi
done
