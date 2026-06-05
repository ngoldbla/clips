# Clipmunk Signed Releases — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebrand Shortcast→Clipmunk and ship Developer ID–signed, notarized macOS DMG releases from CI that launch with no Gatekeeper warning.

**Architecture:** XcodeGen-generated macOS app. A GitHub Actions workflow imports a Developer ID cert into a temp keychain, builds a hardened-runtime Release, notarizes the app and the `create-dmg` DMG with `notarytool`, staples both, and attaches the DMG to the GitHub Release on `v*` tags. A local `scripts/dev-build.sh` gives fast unsigned test builds.

**Tech Stack:** Swift 6 / SwiftUI, XcodeGen, `xcodebuild`, `codesign`, `xcrun notarytool`/`stapler`, `create-dmg`, GitHub Actions (`macos-26`).

**Note on "tests":** this is build/release infra — verification = real commands (`xcodegen generate`, `xcodebuild`, launching the app, `codesign --verify`, `spctl`), not unit tests. Each task ends green before committing.

**Reference:** spec at `docs/superpowers/specs/2026-06-05-clipmunk-signed-releases-design.md`. Six signing secrets already loaded on `ngoldbla/clips`; Team ID `XAHTA7SZUC`.

---

## File structure

| Path | Responsibility | Action |
|------|----------------|--------|
| `Clipmunk/` (was `Shortcast/`) | app sources | rename |
| `Clipmunk/ClipmunkApp.swift` (was `ShortcastApp.swift`) | `@main` entry | rename + edit |
| `project.yml` | XcodeGen project (name, target, signing) | modify |
| `Clipmunk/Info.plist` | bundle display name | modify |
| `Clipmunk/Clipmunk.entitlements` | hardened-runtime entitlements | create |
| `Clipmunk/Assets.xcassets/AppIcon.appiconset/` | app icon (7 PNGs + Contents.json) | populate |
| `assets/Clipmunk.icns`, `assets/clipmunk-mascot.png` | DMG volume icon + README mascot | create |
| `NOTICE`, `README.md` | attribution + docs | modify |
| `scripts/dev-build.sh` | local unsigned build/run | create |
| `.github/workflows/release.yml` | signed+notarized release pipeline | rewrite |

Brand assets to copy FROM (gitignored): `.context/higgsfield/brand/AppIcon.appiconset/`, `.context/higgsfield/brand/Clipmunk.icns`, `.context/higgsfield/round2/07.png`.

---

## Task 1: Rename Shortcast → Clipmunk

**Files:**
- Rename: `Shortcast/` → `Clipmunk/`; `Clipmunk/ShortcastApp.swift` → `Clipmunk/ClipmunkApp.swift`
- Modify: `project.yml`, `Clipmunk/Info.plist`, ~13 `.swift` files referencing "Shortcast"

- [ ] **Step 1: Rename the directory and entry-point file (preserve git history)**

```bash
cd /Users/ngoldbla/conductor/workspaces/clips/bozeman
git mv Shortcast Clipmunk
git mv Clipmunk/ShortcastApp.swift Clipmunk/ClipmunkApp.swift
```

- [ ] **Step 2: Rename the `@main` struct**

In `Clipmunk/ClipmunkApp.swift`, change `struct ShortcastApp: App` → `struct ClipmunkApp: App` (and any `ShortcastApp` references).

- [ ] **Step 3: Update `project.yml`**

Set `name: Clipmunk`. Rename the target `Shortcast:` → `Clipmunk:` and `shortcast-probe:` → `clipmunk-probe:`. Update `sources: - path: Shortcast` → `path: Clipmunk` and every probe `path: Shortcast/...` → `path: Clipmunk/...` (and `PRODUCT_NAME: shortcast-probe` → `clipmunk-probe`). In the app target `settings.base`, set:

```yaml
PRODUCT_BUNDLE_IDENTIFIER: com.github.ngoldbla.Clipmunk
PRODUCT_NAME: Clipmunk
INFOPLIST_FILE: Clipmunk/Info.plist
DEVELOPMENT_TEAM: XAHTA7SZUC
```

(Signing/hardened-runtime settings come in Task 3 — leave the existing `CODE_SIGN_IDENTITY: "-"` / `ENABLE_HARDENED_RUNTIME: NO` for now so this task stays buildable unsigned.)

- [ ] **Step 4: Update `Info.plist`**

In `Clipmunk/Info.plist` set `CFBundleDisplayName` to `Clipmunk`.

- [ ] **Step 5: Bulk-replace user-facing "Shortcast" in source (NOT LICENSE/NOTICE/Vendor)**

```bash
rg -l -s "Shortcast" Clipmunk Probe | while read -r f; do
  sed -i '' 's/Shortcast/Clipmunk/g' "$f"
done
rg -n -s "Shortcast" Clipmunk Probe || echo "no Shortcast left in sources"
```

- [ ] **Step 6: Manually review identifier-bearing strings (data-path break is intentional)**

Inspect and confirm these now read "Clipmunk" (the sweep handles them, but verify intent):
- `Clipmunk/Services/KeychainStore.swift` — the keychain **service name** constant. Renaming means the existing saved Upload-Post API key won't be found (clean break — expected per spec §5A).
- Any **Application Support** / directory name (e.g. `Clipmunk/Services/JobLibrary.swift`, `WorkspaceModel`) using "Shortcast" as a folder → now "Clipmunk". Existing local job data won't carry over (expected).

Run: `rg -n -s -i "application support|FileManager|keychain|service" Clipmunk/Services/KeychainStore.swift Clipmunk/Services/JobLibrary.swift`
Expected: any path/service literals say "Clipmunk".

- [ ] **Step 7: Regenerate the project and verify it builds (unsigned)**

```bash
xcodegen generate
xcodebuild -project Clipmunk.xcodeproj -scheme Clipmunk -configuration Debug \
  -skipMacroValidation -skipPackagePluginValidation \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. (First run resolves SPM packages — may take several minutes.)

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: rename Shortcast -> Clipmunk (dirs, target, bundle id, strings)"
```

---

## Task 2: App icon + branding assets + attribution

**Files:**
- Populate: `Clipmunk/Assets.xcassets/AppIcon.appiconset/` (7 PNGs + Contents.json)
- Create: `assets/Clipmunk.icns`, `assets/clipmunk-mascot.png`
- Modify: `NOTICE`, `README.md`

- [ ] **Step 1: Copy the generated app icon into the asset catalog**

```bash
cd /Users/ngoldbla/conductor/workspaces/clips/bozeman
cp .context/higgsfield/brand/AppIcon.appiconset/icon_*.png Clipmunk/Assets.xcassets/AppIcon.appiconset/
cp .context/higgsfield/brand/AppIcon.appiconset/Contents.json Clipmunk/Assets.xcassets/AppIcon.appiconset/Contents.json
ls Clipmunk/Assets.xcassets/AppIcon.appiconset/
```
Expected: `Contents.json` + `icon_16.png … icon_1024.png` (8 files).

- [ ] **Step 2: Add the DMG volume icon and the README mascot**

```bash
mkdir -p assets
cp .context/higgsfield/brand/Clipmunk.icns assets/Clipmunk.icns
cp .context/higgsfield/round2/07.png assets/clipmunk-mascot.png
ls -1 assets/
```

- [ ] **Step 3: Update `NOTICE` — add Clipmunk, KEEP Shortcast attribution**

Replace the top two lines so it reads (keep everything below "This product includes…" intact):

```
Clipmunk
Copyright 2026 The Clipmunk Authors

Clipmunk is derived from the Shortcast project.

Shortcast
Copyright 2026 The Shortcast Authors

This product includes software developed as part of the Shortcast project,
licensed under the Apache License, Version 2.0 (see LICENSE).
```

- [ ] **Step 4: Update `README.md`**

- Replace "Shortcast" → "Clipmunk" throughout; set the demo image to `assets/clipmunk-mascot.png`.
- Update the **Requirements** section to: Apple Silicon, macOS 15+, **16 GB RAM minimum / 24 GB+ recommended**, **~12–14 GB free disk** for first-run model downloads.
- Leave the `xattr`/"damaged" Install note for now (Task 6 removes it once a notarized release exists).

- [ ] **Step 5: Regenerate, build, and confirm the icon is wired in**

```bash
xcodegen generate
xcodebuild -project Clipmunk.xcodeproj -scheme Clipmunk -configuration Debug \
  -skipMacroValidation -skipPackagePluginValidation -derivedDataPath build \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
ls build/Build/Products/Debug/Clipmunk.app/Contents/Resources/*.icns 2>/dev/null && echo "icon compiled in"
open build/Build/Products/Debug/Clipmunk.app   # eyeball: Dock icon = Clipmunk
```
Expected: BUILD SUCCEEDED; a compiled `AppIcon.icns` present; the launched app shows the chipmunk icon in the Dock.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add Clipmunk app icon, mascot, DMG icon; update NOTICE/README"
```

---

## Task 3: Signing config + entitlements + hardened-runtime launch gate

**Files:**
- Modify: `project.yml` (per-config signing)
- Create: `Clipmunk/Clipmunk.entitlements`

- [ ] **Step 1: Create a minimal entitlements file**

`Clipmunk/Clipmunk.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
```

- [ ] **Step 2: Move signing settings into per-configuration blocks in `project.yml`**

In the `Clipmunk` target, remove `CODE_SIGN_IDENTITY: "-"` and `ENABLE_HARDENED_RUNTIME: NO` from `settings.base`, and add:

```yaml
    settings:
      base:
        # ...existing shared settings (bundle id, product name, swift, etc.)...
      configs:
        Debug:
          CODE_SIGNING_ALLOWED: NO
        Release:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Developer ID Application"
          DEVELOPMENT_TEAM: XAHTA7SZUC
          ENABLE_HARDENED_RUNTIME: YES
          CODE_SIGN_ENTITLEMENTS: Clipmunk/Clipmunk.entitlements
          OTHER_CODE_SIGN_FLAGS: "--timestamp"
```

- [ ] **Step 3: Regenerate and build a SIGNED, hardened Release locally**

(The Developer ID identity is already in this Mac's keychain.)

```bash
xcodegen generate
xcodebuild -project Clipmunk.xcodeproj -scheme Clipmunk -configuration Release \
  -skipMacroValidation -skipPackagePluginValidation -derivedDataPath build \
  -destination 'platform=macOS' clean build 2>&1 | tail -20
codesign --verify --strict --verbose=2 build/Build/Products/Release/Clipmunk.app
codesign -dv --verbose=4 build/Build/Products/Release/Clipmunk.app 2>&1 | grep -E "Authority|Runtime|flags"
```
Expected: BUILD SUCCEEDED; `--verify` prints `valid on disk` / `satisfies its Designated Requirement`; `flags=0x10000(runtime)` present (hardened runtime on).

- [ ] **Step 4: THE MLX GATE — launch the hardened build and run a real generation**

```bash
open build/Build/Products/Release/Clipmunk.app
```
Then in the app: drop a short video (or use "Caption a short") and run one generation so the **MLX model actually loads and infers**. Watch for an immediate crash. Also check Console:
```bash
log show --last 5m --predicate 'process == "Clipmunk"' 2>/dev/null | grep -iE "jit|executable|codesign|killed|EXC_" | head
```
Expected: the generation completes; **no** `EXC_BAD_ACCESS`/"killed"/JIT-related crash. (Requires first-run model download — allow time + disk.)

- [ ] **Step 5: If (and only if) it crashed under hardened runtime — escalate entitlements minimally**

Add to `Clipmunk.entitlements`, ONE at a time, regenerating + rebuilding + re-launching after each, stopping as soon as it works:

```xml
  <key>com.apple.security.cs.allow-jit</key><true/>
```
then if still failing:
```xml
  <key>com.apple.security.cs.disable-library-validation</key><true/>
```
then if still failing:
```xml
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
```
Record which were needed and why in a comment in the entitlements file. (If none were needed, keep it empty — best case.)

- [ ] **Step 6: Commit**

```bash
git add project.yml Clipmunk/Clipmunk.entitlements
git commit -m "feat: Developer ID signing + hardened runtime (entitlements finalized via launch test)"
```

---

## Task 4: Local dev-build script

**Files:**
- Create: `scripts/dev-build.sh`

- [ ] **Step 1: Write the script**

`scripts/dev-build.sh`:

```bash
#!/usr/bin/env bash
# Fast LOCAL build for testing — unsigned, no notarization. Signed DMGs come from CI.
# Usage: scripts/dev-build.sh [--dmg] [--open]
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="build"
echo "==> xcodegen generate"; xcodegen generate
echo "==> building (Debug, unsigned)"
xcodebuild -project Clipmunk.xcodeproj -scheme Clipmunk -configuration Debug \
  -skipMacroValidation -skipPackagePluginValidation -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
APP="$DERIVED/Build/Products/Debug/Clipmunk.app"
echo "built: $APP"
if [[ "${1:-}" == "--dmg" || "${2:-}" == "--dmg" ]]; then
  command -v create-dmg >/dev/null || brew install create-dmg
  mkdir -p dist
  create-dmg --volname "Clipmunk (dev)" --volicon "assets/Clipmunk.icns" \
    --window-size 540 380 --icon-size 110 --icon "Clipmunk.app" 150 190 \
    --app-drop-link 390 190 --hdiutil-quiet "dist/Clipmunk-dev.dmg" "$APP" || true
  echo "dmg: dist/Clipmunk-dev.dmg"
fi
if [[ "${1:-}" == "--open" || "${2:-}" == "--open" ]]; then open "$APP"; fi
```

- [ ] **Step 2: Make executable and run it**

```bash
chmod +x scripts/dev-build.sh
./scripts/dev-build.sh --open
```
Expected: BUILD SUCCEEDED and Clipmunk launches.

- [ ] **Step 3: Commit**

```bash
git add scripts/dev-build.sh
git commit -m "chore: add local dev-build script"
```

---

## Task 5: CI release workflow (signed + notarized)

**Files:**
- Rewrite: `.github/workflows/release.yml`

- [ ] **Step 1: Replace the workflow with the signed+notarized pipeline**

`.github/workflows/release.yml`:

```yaml
name: Release
on:
  push:
    tags: ["v*"]
  workflow_dispatch:
permissions:
  contents: write
jobs:
  build-dmg:
    runs-on: macos-26
    env:
      APP_NAME: Clipmunk
      SCHEME: Clipmunk
    steps:
      - uses: actions/checkout@v4

      - name: Install tools
        run: brew install xcodegen create-dmg

      - name: Import Developer ID cert into a temporary keychain
        env:
          DEVID_CERT_P12_BASE64: ${{ secrets.DEVID_CERT_P12_BASE64 }}
          DEVID_CERT_PASSWORD: ${{ secrets.DEVID_CERT_PASSWORD }}
        run: |
          set -euo pipefail
          KEYCHAIN="$RUNNER_TEMP/clipmunk.keychain-db"
          KPW="$(uuidgen)"
          echo "$DEVID_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
          security create-keychain -p "$KPW" "$KEYCHAIN"
          security set-keychain-settings -lut 21600 "$KEYCHAIN"
          security unlock-keychain -p "$KPW" "$KEYCHAIN"
          security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" \
            -P "$DEVID_CERT_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple: -s -k "$KPW" "$KEYCHAIN" >/dev/null
          security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
          echo "KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"

      - name: Generate Xcode project
        run: xcodegen generate

      - name: Build (Release, Developer ID, hardened runtime)
        run: |
          set -euo pipefail
          xcodebuild -project Clipmunk.xcodeproj -scheme "$SCHEME" -configuration Release \
            -derivedDataPath build -skipMacroValidation -skipPackagePluginValidation \
            -destination 'platform=macOS' \
            CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
            DEVELOPMENT_TEAM="${{ secrets.APPLE_TEAM_ID }}" \
            OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
            clean build
          codesign --verify --strict --verbose=2 "build/Build/Products/Release/$APP_NAME.app"

      - name: Notarize and staple the app
        env:
          NOTARY_KEY_P8: ${{ secrets.NOTARY_KEY_P8 }}
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
        run: |
          set -euo pipefail
          APP="build/Build/Products/Release/$APP_NAME.app"
          printf '%s' "$NOTARY_KEY_P8" > "$RUNNER_TEMP/key.p8"
          ditto -c -k --keepParent "$APP" "$RUNNER_TEMP/$APP_NAME.zip"
          xcrun notarytool submit "$RUNNER_TEMP/$APP_NAME.zip" \
            --key "$RUNNER_TEMP/key.p8" --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" --wait
          xcrun stapler staple "$APP"

      - name: Build, sign, notarize, staple the DMG
        env:
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
        run: |
          set -euo pipefail
          APP="build/Build/Products/Release/$APP_NAME.app"
          mkdir -p dist
          # create-dmg can exit nonzero on AppleScript timing even on success → retry, then check file exists
          for i in 1 2 3; do
            create-dmg --volname "Clipmunk" --volicon "assets/Clipmunk.icns" \
              --window-size 540 380 --icon-size 110 \
              --icon "$APP_NAME.app" 150 190 --app-drop-link 390 190 --hdiutil-quiet \
              "dist/$APP_NAME.dmg" "$APP" && break || sleep 5
          done
          test -f "dist/$APP_NAME.dmg"
          codesign --force --sign "Developer ID Application" --timestamp "dist/$APP_NAME.dmg"
          xcrun notarytool submit "dist/$APP_NAME.dmg" \
            --key "$RUNNER_TEMP/key.p8" --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" --wait
          xcrun stapler staple "dist/$APP_NAME.dmg"

      - name: Verify notarization
        run: |
          spctl -a -t open --context context:primary-signature -v "dist/$APP_NAME.dmg" || true
          xcrun stapler validate "dist/$APP_NAME.dmg"

      - name: Upload DMG artifact (always)
        uses: actions/upload-artifact@v4
        with:
          name: Clipmunk-dmg
          path: dist/Clipmunk.dmg

      - name: Attach DMG to the Release (tags only)
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          files: dist/Clipmunk.dmg
          fail_on_unmatched_files: true

      - name: Clean up keychain
        if: always()
        run: security delete-keychain "$KEYCHAIN" || true
```

- [ ] **Step 2: Commit and push the branch**

```bash
git add .github/workflows/release.yml
git commit -m "ci: signed + notarized Clipmunk DMG release workflow"
git push -u origin ngoldbla/signed-mac-binary-releases
```

- [ ] **Step 3: Dry-run the whole pipeline via workflow_dispatch (no tag, no release)**

```bash
gh workflow run "Release" --ref ngoldbla/signed-mac-binary-releases
sleep 5
gh run list --workflow=Release --limit 1
RUN=$(gh run list --workflow=Release --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN" --exit-status
```
Expected: the run completes green; the **Verify notarization** step shows `accepted` / `source=Notarized Developer ID` and `stapler validate` succeeds; a `Clipmunk-dmg` artifact is produced.

- [ ] **Step 4: If the run fails, fix forward**

Common fixes: keychain partition-list (already included), `.p8` newline (we use `printf`), MLX entitlements (mirror Task 3's final entitlements — they're in the signed build automatically), create-dmg flakiness (retry loop included). Inspect with `gh run view "$RUN" --log-failed`, fix, recommit, re-dispatch.

---

## Task 6: First real release + final docs

**Files:**
- Modify: `README.md` (drop the `xattr` workaround)

- [ ] **Step 1: Tag and push a release**

```bash
git tag v0.1.0
git push origin v0.1.0
RUN=$(gh run list --workflow=Release --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN" --exit-status
gh release view v0.1.0 --json assets -q '.assets[].name'
```
Expected: a `v0.1.0` Release exists with `Clipmunk.dmg` attached.

- [ ] **Step 2: Manual Gatekeeper check on a clean machine**

Download `Clipmunk.dmg` from the Release on a **different** Mac (or an account that never built it), open it, drag to Applications, double-click. Expected: **opens with no warning** (no "unidentified developer", no "damaged", no `xattr` needed).

- [ ] **Step 3: Remove the now-obsolete workaround from `README.md`**

Delete the `xattr -dr com.apple.quarantine` Install steps and the "damaged" NOTE block; replace with "Download `Clipmunk.dmg`, open it, drag Clipmunk to Applications, launch it."

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: signed releases — drop the Gatekeeper xattr workaround"
```

---

## Self-review (done)

- **Spec coverage:** §5A rebrand → T1+T2; §5B signing/entitlements/MLX gate → T3; §5C CI → T5; §5D create-dmg → T5; §5E requirements → T2 (README); §5F dev script → T4; §5G verification → T5/T6. All covered.
- **Placeholders:** none — full YAML, full script, full entitlements provided. The only conditional is T3 Step 5 (entitlement escalation), which is gated on an observed crash and lists exact keys.
- **Consistency:** names match across tasks — target/scheme `Clipmunk`, bundle id `com.github.ngoldbla.Clipmunk`, DMG `dist/Clipmunk.dmg`, secret names match §4 and the workflow `env`.
- **Known caveat:** T3 Step 4 needs a real model download (time + ~7 GB disk). T6 Step 2 needs a second Mac for a true clean-room test.
