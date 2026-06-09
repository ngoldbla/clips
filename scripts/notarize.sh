#!/usr/bin/env bash
# Notarize a .app .zip or a .dmg: upload ONCE, then patiently poll that same
# submission until Apple reaches a terminal state or we hit a total deadline.
#
# Why not `notarytool submit --wait` with a timeout + resubmit?
#   `--wait` has no internal cap, so a stalled Apple Notary service (submission
#   stuck at "In Progress…") hangs until the CI job's limit kills it — that is
#   how the v0.0.1 run burned 6 hours. The obvious fix (cap each `--wait` with
#   `--timeout` and resubmit) is *also* wrong when Apple is merely backlogged:
#   each timeout ABANDONS a submission Apple is still processing and enqueues a
#   fresh one at the back of the queue, so it can never catch up (this is what
#   failed both 2026-06-08/09 dry-runs — three 25-min waits, none completing).
#
#   Instead: upload once (`--no-wait`), capture the submission id, and poll
#   `notarytool info` ourselves for up to NOTARIZE_DEADLINE_MIN minutes. The one
#   submission gets the full budget, so a slow-but-working notary succeeds. Only
#   the UPLOAD is retried (genuine network/5xx), never the wait. A terminal
#   Invalid/Rejected is surfaced with its log and fails immediately.
#
# Usage:   scripts/notarize.sh <path-to-zip-or-dmg>
# Env:     NOTARY_KEY_P8, NOTARY_KEY_ID, NOTARY_ISSUER_ID        (required)
#          NOTARIZE_DEADLINE_MIN (default 45)  total minutes to wait on one submission
#          NOTARIZE_POLL_SEC     (default 20)  seconds between status polls
#          NOTARIZE_UPLOAD_TRIES (default 3)   retries for the upload step only
set -euo pipefail

ARTIFACT="${1:?usage: notarize.sh <path-to-zip-or-dmg>}"
: "${NOTARY_KEY_P8:?NOTARY_KEY_P8 is required}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"

KEY="${RUNNER_TEMP:-/tmp}/notary-key.p8"
printf '%s' "$NOTARY_KEY_P8" > "$KEY"
AUTH=(--key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

DEADLINE_MIN="${NOTARIZE_DEADLINE_MIN:-45}"
POLL_SEC="${NOTARIZE_POLL_SEC:-20}"
UPLOAD_TRIES="${NOTARIZE_UPLOAD_TRIES:-3}"

# Extract a top-level JSON string field without depending on jq.
json_field() { /usr/bin/python3 -c 'import sys,json
try: print(json.load(sys.stdin).get(sys.argv[1],""))
except Exception: print("")' "$1"; }

# 1. Upload once. Retry ONLY the upload itself (network / 5xx), not the wait.
id=""
for t in $(seq 1 "$UPLOAD_TRIES"); do
  echo "==> uploading $(basename "$ARTIFACT") to Apple Notary (upload ${t}/${UPLOAD_TRIES})"
  set +e
  OUT="$(xcrun notarytool submit "$ARTIFACT" "${AUTH[@]}" --no-wait --output-format json 2>&1)"
  code=$?
  set -e
  echo "$OUT"
  id="$(printf '%s' "$OUT" | json_field id)"
  [ "$code" -eq 0 ] && [ -n "$id" ] && break
  echo "==> upload attempt ${t} failed; retrying in 30s…"
  sleep 30
done
[ -n "$id" ] || { echo "==> could not upload to Apple Notary after ${UPLOAD_TRIES} tries"; exit 1; }
echo "==> submission id: $id — polling for up to ${DEADLINE_MIN} min"

# 2. Poll the SAME submission until terminal or deadline.
deadline=$(( $(date +%s) + DEADLINE_MIN * 60 ))
while :; do
  set +e
  INFO="$(xcrun notarytool info "$id" "${AUTH[@]}" --output-format json 2>&1)"
  set -e
  status="$(printf '%s' "$INFO" | json_field status)"

  case "$status" in
    Accepted)
      echo "==> notarization accepted"
      exit 0
      ;;
    Invalid|Rejected)
      echo "==> notarization $status — fetching log for ${id}"
      xcrun notarytool log "$id" "${AUTH[@]}" || true
      exit 1
      ;;
  esac

  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "==> still '${status:-unknown}' after ${DEADLINE_MIN} min — Apple Notary is stalled (not a signing problem); try again once Apple's Notary service recovers"
    exit 1
  fi
  echo "   status: ${status:-unknown}  ($(( (deadline - now) / 60 )) min left)"
  sleep "$POLL_SEC"
done
