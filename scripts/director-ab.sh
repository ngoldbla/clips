#!/usr/bin/env bash
# Closed-loop A/B for the Director (the single LLM that finds moments + writes
# captions). Runs Clipmunk's shorts pipeline twice over the same video with two
# different Director model ids, and captures each run's raw moment JSON + per-phase
# timing so the two can be judged side by side.
#
# Primary use: validate the unsloth UD build of Gemma 4 E2B against the standard
# MLX 4-bit baseline ("prefer unsloth if it works"). Both are gemma4-family, so
# both load through the same `.gemma4Text` path via the DEBUG CLIPMUNK_DIRECTOR_MODEL
# override — no rebuild needed to swap them.
#
# Usage:
#   scripts/director-ab.sh [video] [modelA] [modelB]
# Defaults: the trimmed test clip, standard E2B vs unsloth UD E2B.
#
# Requires a Debug build:  scripts/dev-build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VIDEO="${1:-$PWD/.context/testclip.mp4}"
MODEL_A="${2:-mlx-community/gemma-4-e2b-it-4bit}"
MODEL_B="${3:-unsloth/gemma-4-E2B-it-UD-MLX-4bit}"
BIN="build/Build/Products/Debug/Clipmunk.app/Contents/MacOS/Clipmunk"
OUT=".context/ab-director"
mkdir -p "$OUT"

[ -x "$BIN" ] || { echo "build the app first (scripts/dev-build.sh)"; exit 1; }
[ -f "$VIDEO" ] || { echo "no video at $VIDEO"; exit 1; }

run() {
  local label="$1" model="$2"
  local log="$OUT/$label.log"
  : > "$log"
  echo "==> $label  ($model)"
  CLIPMUNK_AUTORUN_VIDEO="$VIDEO" \
  CLIPMUNK_DIRECTOR_MODEL="$model" \
    "$BIN" > "$log" 2>&1 &
  local pid=$!
  local waited=0
  until grep -qE "pipeline done|Couldn't make shorts|director load FAILED|MomentFinderError|TranscriptionError" "$log" 2>/dev/null; do
    sleep 6; waited=$((waited+6))
    kill -0 "$pid" 2>/dev/null || { echo "  app exited early at ${waited}s"; break; }
    [ "$waited" -gt 1400 ] && { echo "  timeout"; break; }
  done
  sleep 2; kill "$pid" 2>/dev/null || true
  pkill -f "Clipmunk.app/Contents/MacOS/Clipmunk" 2>/dev/null || true
  sleep 1
  # Pull the headline signals for the report.
  echo "  --- $label result ---"
  grep -E "director loaded|director load FAILED|findMoments timing|found [0-9]+ moment|parser: .* built" "$log" | sed 's/^/    /' || true
}

run A "$MODEL_A"
run B "$MODEL_B"

echo ""
echo "=== DONE — logs in $OUT/ (A.log, B.log) ==="
echo "  A = $MODEL_A"
echo "  B = $MODEL_B"
echo "  Compare: did each load? prefill/gen tok/s, clip count, JSON validity."
