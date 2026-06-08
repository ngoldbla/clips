#!/usr/bin/env bash
# Closed-loop A/B for the vision-aware moment-finder.
#
# Runs Clipmunk's shorts pipeline twice over the same video — once transcript-only
# (the blind Director, baseline) and once with the Marlin-2B vision pass merged in
# (augmented) — and captures each run's Director output so the two moment lists can
# be judged side by side. The augmented run also dumps the exact "what's on screen,
# when" track fed to the Director.
#
# Usage:
#   scripts/vision-ab.sh [video.mp4] [director-hf-id]
# Defaults to the sample video + the 16 GB default Director (Qwen 3.5 4B).
#
# Requires a Debug build:  scripts/dev-build.sh   (or the marlin build steps).
set -euo pipefail
cd "$(dirname "$0")/.."

VIDEO="${1:-$PWD/.context/testcase/J6v61QQqsC8.mp4}"
DIRECTOR="${2:-mlx-community/Qwen3.5-4B-MLX-4bit}"
BIN="build/Build/Products/Debug/Clipmunk.app/Contents/MacOS/Clipmunk"
OUT=".context/ab"
mkdir -p "$OUT"

[ -x "$BIN" ] || { echo "build the app first (scripts/dev-build.sh)"; exit 1; }
[ -f "$VIDEO" ] || { echo "no video at $VIDEO"; exit 1; }

# Run the pipeline until the Director has chosen moments, then stop the app
# (we don't need the slow cut/reframe loop for the A/B).
run() {
  local label="$1"
  local vision="$2"
  local log="$OUT/$label.log"
  : > "$log"
  echo "==> $label (vision=$vision) — $VIDEO"
  CLIPMUNK_AUTORUN_VIDEO="$VIDEO" \
  CLIPMUNK_VISION_PASS="$vision" \
  CLIPMUNK_DIRECTOR_MODEL="$DIRECTOR" \
  CLIPMUNK_VISION_DUMP="$PWD/$OUT/$label.augmented-transcript.txt" \
    "$BIN" > "$log" 2>&1 &
  local pid=$!
  # wait for the Director to finish (or failure), with a generous ceiling
  local waited=0
  until grep -qE "found [0-9]+ moment|pipeline failed|vision pass FAILED|❌|MomentFinderError" "$log" 2>/dev/null; do
    sleep 5; waited=$((waited+5))
    if ! kill -0 "$pid" 2>/dev/null; then echo "  app exited early"; break; fi
    if [ "$waited" -gt 1500 ]; then echo "  timeout"; break; fi
  done
  sleep 2
  kill "$pid" 2>/dev/null || true
  pkill -f "Clipmunk.app/Contents/MacOS/Clipmunk" 2>/dev/null || true
  sleep 1
  echo "  log: $log"
}

run baseline 0
run augmented 1

echo ""
echo "=== DONE — artifacts in $OUT/ ==="
echo "  baseline.log / augmented.log  (per-phase timing + Director raw JSON)"
echo "  augmented.augmented-transcript.txt  (the WHAT+WHEN track fed to the Director)"
