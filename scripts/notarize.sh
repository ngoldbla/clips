#!/usr/bin/env bash
# Notarize a .app .zip or a .dmg with a per-attempt timeout + retries.
#
# Why: `xcrun notarytool submit --wait` has no internal cap. When Apple's Notary
# service stalls (submission stuck at "In Progress…" — a transient outage), the
# bare `--wait` hangs until the CI job's 6-hour limit kills it. That is exactly
# how the v0.0.1 Release run failed. Here we cap each wait with `--timeout` and
# resubmit a few times, so an Apple-side stall fails fast and self-heals instead
# of burning the whole job. A genuine rejection (status: Invalid) is NOT retried —
# we dump the notary log and fail immediately.
#
# Usage:   scripts/notarize.sh <path-to-zip-or-dmg>
# Env:     NOTARY_KEY_P8, NOTARY_KEY_ID, NOTARY_ISSUER_ID   (required)
#          NOTARIZE_ATTEMPTS (default 3), NOTARIZE_TIMEOUT (default 45m)
set -euo pipefail

ARTIFACT="${1:?usage: notarize.sh <path-to-zip-or-dmg>}"
: "${NOTARY_KEY_P8:?NOTARY_KEY_P8 is required}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"

KEY="${RUNNER_TEMP:-/tmp}/notary-key.p8"
printf '%s' "$NOTARY_KEY_P8" > "$KEY"

ATTEMPTS="${NOTARIZE_ATTEMPTS:-3}"
TIMEOUT="${NOTARIZE_TIMEOUT:-45m}"

for attempt in $(seq 1 "$ATTEMPTS"); do
  echo "==> notarizing $(basename "$ARTIFACT") (attempt ${attempt}/${ATTEMPTS}, per-attempt timeout ${TIMEOUT})"
  set +e
  OUT="$(xcrun notarytool submit "$ARTIFACT" \
    --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout "$TIMEOUT" 2>&1)"
  code=$?
  set -e
  echo "$OUT"

  if [ "$code" -eq 0 ] && echo "$OUT" | grep -q "status: Accepted"; then
    echo "==> notarization accepted"
    exit 0
  fi

  # A terminal rejection won't change on retry — surface the reason and stop.
  if echo "$OUT" | grep -q "status: Invalid"; then
    id="$(echo "$OUT" | awk '/id:/{print $2; exit}')"
    echo "==> notarization REJECTED (status: Invalid) — fetching log for ${id}"
    [ -n "$id" ] && xcrun notarytool log "$id" \
      --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
    exit 1
  fi

  echo "==> attempt ${attempt} did not complete (timeout or transient error); retrying in 30s…"
  sleep 30
done

echo "==> notarization did not complete after ${ATTEMPTS} attempts (Apple Notary likely stalled)"
exit 1
