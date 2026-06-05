#!/usr/bin/env bash
# Fast LOCAL build for testing — unsigned, no notarization.
# Signed/notarized DMGs come from CI (.github/workflows/release.yml).
#
# Usage:
#   scripts/dev-build.sh            # build Debug (unsigned)
#   scripts/dev-build.sh --open     # build + launch the app
#   scripts/dev-build.sh --dmg      # build + package an unsigned dev DMG
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="build"

# Xcode 26 unbundled the Metal Toolchain; MLX compiles .metal kernels at build
# time, so make sure it's present (no-op if already installed).
if ! xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q "installed"; then
  echo "==> downloading Metal Toolchain (one-time, ~688 MB)"
  xcodebuild -downloadComponent MetalToolchain
fi

echo "==> xcodegen generate"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

echo "==> building Clipmunk (Debug, unsigned)"
xcodebuild -project Clipmunk.xcodeproj -scheme Clipmunk -configuration Debug \
  -skipMacroValidation -skipPackagePluginValidation -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

APP="$DERIVED/Build/Products/Debug/Clipmunk.app"
echo "built: $APP"

for arg in "$@"; do
  case "$arg" in
    --dmg)
      command -v create-dmg >/dev/null || brew install create-dmg
      mkdir -p dist
      rm -f "dist/Clipmunk-dev.dmg"
      create-dmg --volname "Clipmunk (dev)" --volicon "assets/Clipmunk.icns" \
        --window-size 540 380 --icon-size 110 --icon "Clipmunk.app" 150 190 \
        --app-drop-link 390 190 --hdiutil-quiet "dist/Clipmunk-dev.dmg" "$APP" || true
      echo "dmg: dist/Clipmunk-dev.dmg"
      ;;
    --open)
      open "$APP"
      ;;
  esac
done
