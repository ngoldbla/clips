# Clipmunk — Signed & Notarized macOS Releases (+ Shortcast→Clipmunk rebrand)

- **Date:** 2026-06-05
- **Status:** Approved design — ready for implementation plan
- **Repo:** `github.com/ngoldbla/clips` (branch `ngoldbla/signed-mac-binary-releases`)

## 1. Goal

Ship real **Developer ID–signed and notarized** macOS releases so a downloaded
`.dmg` launches with **no Gatekeeper warning** (no more `xattr` / "damaged" workaround),
and provide a fast **local build** for quick testing. Do this as part of rebranding the
app from **Shortcast** to **Clipmunk**.

## 2. Context (current state)

- Native SwiftUI app, Apple Silicon, macOS 15+. Built with **XcodeGen** (`project.yml` →
  `Clipmunk.xcodeproj`, not committed) → `xcodebuild`. On-device WhisperKit + Gemma 4 (MLX).
- Today: **unsigned** (`CODE_SIGN_IDENTITY: "-"`, `ENABLE_HARDENED_RUNTIME: NO`, no entitlements);
  `.github/workflows/release.yml` builds an unsigned DMG on `v*` tags. `AppIcon.appiconset`
  is an empty placeholder.
- Distribution channel: **Developer ID + notarized DMG** (NOT Mac App Store) → App-Store
  name-uniqueness/sandbox rules don't apply.

## 3. Decisions (locked)

| # | Decision |
|---|----------|
| Name | **Clipmunk** (chipmunk that "clips" best moments) |
| Bundle ID | **`com.github.ngoldbla.Clipmunk`** |
| Signing approach | **B — CI-only** (GitHub Actions on `v*` tag) |
| Notarization | App Store Connect **API key** via `notarytool` |
| Source folder | **Rename `Shortcast/` → `Clipmunk/`** (full rebrand) |
| DMG tool | **`create-dmg`** (styled window + volume icon) |
| Local testing | **`scripts/dev-build.sh`** — fast local *unsigned* build/run |
| Branding | mascot = `.context/higgsfield/brand/` `07.png`; app icon = generated `AppIcon.appiconset` + `Clipmunk.icns` |

## 4. Apple credentials — DONE (2026-06-05)

Team **Kennesaw State University Research and Service Foundation, Inc.**, account holder Dylan
Goldblatt. The existing **"Developer ID Application: …(XAHTA7SZUC)"** identity (already in this
Mac's keychain with its private key) is reused; an App Store Connect API key
("Clipmunk Notarization", role Developer) was created for notarization.

**Six GitHub secrets are already loaded on `ngoldbla/clips`:**

| Secret | Value source | Used by |
|--------|--------------|---------|
| `APPLE_TEAM_ID` | `XAHTA7SZUC` | codesign + notarytool |
| `NOTARY_KEY_ID` | `D9R84FK228` | notarytool |
| `NOTARY_ISSUER_ID` | `abb9a778-ca8e-4a78-875a-951c3715ab2a` | notarytool |
| `NOTARY_KEY_P8` | `AuthKey_D9R84FK228.p8` contents | notarytool |
| `DEVID_CERT_P12_BASE64` | base64 of `Clipmunk_DevID.p12` | codesign |
| `DEVID_CERT_PASSWORD` | `.p12` export password | codesign |

Local copies (only copies — back up off-repo): `~/Downloads/AuthKey_D9R84FK228.p8`,
`~/Desktop/Clipmunk_DevID.p12`, `~/clipmunk-signing/p12_pass.txt`.

## 5. Work breakdown

### 5A. Rebrand Shortcast → Clipmunk
- **Rename directory** `Shortcast/` → `Clipmunk/` (git mv). Rename `Shortcast/ShortcastApp.swift`
  → `Clipmunk/ClipmunkApp.swift` and the `@main struct ShortcastApp` → `ClipmunkApp`.
- `project.yml`: `name: Clipmunk`; target `Shortcast` → `Clipmunk` (scheme follows);
  `sources: - path: Clipmunk`; probe target `shortcast-probe` → `clipmunk-probe` with its
  `path:` references updated to `Clipmunk/...`; settings:
  `PRODUCT_NAME: Clipmunk`, `PRODUCT_BUNDLE_IDENTIFIER: com.github.ngoldbla.Clipmunk`,
  `INFOPLIST_FILE: Clipmunk/Info.plist`, `DEVELOPMENT_TEAM: XAHTA7SZUC`.
- `Info.plist`: `CFBundleDisplayName: Clipmunk`.
- Codebase string sweep: replace user-facing "Shortcast" → "Clipmunk" across the ~13 files
  that mention it. **Audit identifier-bearing strings carefully:**
  - **Keychain service name** (`KeychainStore.swift`) and **Application Support dir** (e.g.
    JobLibrary / job storage) — renaming changes where data lives, so existing local data
    won't carry over. Acceptable for a rebrand; **note in the plan**, don't silently migrate.
- `NOTICE`: add a **Clipmunk** copyright line **above** the retained "Shortcast project,
  Apache-2.0" attribution (license §4 requires keeping it). Keep `LICENSE`.
- `README.md`: name, demo image (mascot), Install (now signed — drop the `xattr`/"damaged"
  section once a notarized release exists), Requirements (§5E), build-from-source.
- **Icons:** copy `.context/higgsfield/brand/AppIcon.appiconset/*` (7 PNGs + Contents.json)
  into `Clipmunk/Assets.xcassets/AppIcon.appiconset/`. Add `Clipmunk.icns` (repo path, e.g.
  `assets/Clipmunk.icns`) for the DMG volume icon. Copy mascot `07.png` → `assets/`.

### 5B. Signing config + entitlements
- `project.yml` Release settings: `CODE_SIGN_STYLE: Manual`,
  `CODE_SIGN_IDENTITY: "Developer ID Application"`, `ENABLE_HARDENED_RUNTIME: YES`,
  `CODE_SIGN_ENTITLEMENTS: Clipmunk/Clipmunk.entitlements`. Keep ad-hoc/unsigned for Debug
  so local dev needs no cert.
- New `Clipmunk/Clipmunk.entitlements` — **start minimal** (Developer-ID apps are NOT
  sandboxed; no `com.apple.security.app-sandbox`).
- **MLX hardened-runtime gate (critical, do this before trusting CI):** build a hardened +
  signed Release locally, **launch it and run one real generation**. If MLX/Metal crashes
  under hardened runtime, add the *minimum* entitlement that fixes it, in this order, testing
  after each: `com.apple.security.cs.allow-jit` → `com.apple.security.cs.disable-library-validation`
  → `com.apple.security.cs.allow-unsigned-executable-memory`. Record the final set + why.

### 5C. CI workflow (`.github/workflows/release.yml`)
Trigger: `push` tags `v*` + `workflow_dispatch`. Runner: `macos-26`. Steps:
1. `brew install xcodegen create-dmg`.
2. **Import cert into a temporary keychain** (deleted on exit):
   ```bash
   KEYCHAIN="$RUNNER_TEMP/clipmunk.keychain-db"; KPW="$(uuidgen)"
   echo "$DEVID_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
   security create-keychain -p "$KPW" "$KEYCHAIN"
   security set-keychain-settings -lut 21600 "$KEYCHAIN"
   security unlock-keychain -p "$KPW" "$KEYCHAIN"
   security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" -P "$DEVID_CERT_PASSWORD" -T /usr/bin/codesign
   security set-key-partition-list -S apple-tool:,apple: -s -k "$KPW" "$KEYCHAIN"
   security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
   ```
3. `xcodegen generate`.
4. Build signed + hardened:
   ```bash
   xcodebuild -project Clipmunk.xcodeproj -scheme Clipmunk -configuration Release \
     -derivedDataPath build -skipMacroValidation -skipPackagePluginValidation \
     CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
     DEVELOPMENT_TEAM="$APPLE_TEAM_ID" OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
     clean build
   ```
5. `codesign --verify --strict --verbose=2 build/.../Clipmunk.app`.
6. **Notarize the app** (pass `.p8` via a file written from the `NOTARY_KEY_P8` env, preserving
   newlines; never inline-expand):
   ```bash
   printf '%s' "$NOTARY_KEY_P8" > "$RUNNER_TEMP/key.p8"
   ditto -c -k --keepParent "$APP" "$RUNNER_TEMP/Clipmunk.zip"
   xcrun notarytool submit "$RUNNER_TEMP/Clipmunk.zip" --key "$RUNNER_TEMP/key.p8" \
     --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
   xcrun stapler staple "$APP"
   ```
7. **Build the DMG** with `create-dmg` (styled window, `/Applications` link, volume icon),
   then **codesign → notarize → staple the DMG**.
8. Attach the stapled DMG to the Release (`softprops/action-gh-release@v2`, tags only).
9. `if: always()` → `security delete-keychain "$KEYCHAIN"`.

Secret newline care: pass `.p8` through an env var → file (not `echo "${{ secrets… }}"`),
since the PEM is multi-line.

### 5D. DMG (create-dmg)
```bash
create-dmg --volname "Clipmunk" --volicon "assets/Clipmunk.icns" \
  --window-size 540 380 --icon-size 110 \
  --icon "Clipmunk.app" 150 190 --app-drop-link 390 190 --hdiutil-quiet \
  "dist/Clipmunk.dmg" "build/Build/Products/Release/Clipmunk.app"
```
(Optional later: `--background assets/dmg-bg.png` for a branded backdrop.) `create-dmg`
returns nonzero on AppleScript timing flakiness even on success → handle/retry in CI.

### 5E. Requirements (README)
- Apple Silicon, macOS 15+. **16 GB RAM minimum, 24 GB+ recommended** (24 GB lets the
  Director + copywriter stay resident; the app already gates on `systemRAMGB >= 24`).
- **~12–14 GB free disk** for first-run model downloads (Gemma 12B ≈7 GB, Gemma E4B 5 GB,
  WhisperKit ≈1.5 GB) + working video scratch. Models download on first run from Hugging Face.

### 5F. Local dev build (`scripts/dev-build.sh`)
Fast iteration, no cert: `xcodegen generate` → `xcodebuild -configuration Debug`
(`CODE_SIGNING_ALLOWED=NO` or ad-hoc) → optional `open` of the built `.app`. Optionally a
`--dmg` flag to package an unsigned DMG for hand-testing. This is the "test quickly" path;
the signed DMG always comes from CI.

### 5G. Verification
- In CI: `codesign -dv --verbose=4`, `spctl -a -t open --context context:primary-signature
  dist/Clipmunk.dmg` (expects "accepted, source=Notarized Developer ID"), `stapler validate`.
- Manual for the first release: download the DMG on a **different** Mac, double-click → app
  opens with **no warning**.

## 6. Risks & mitigations
- **MLX under hardened runtime** → explicit local launch-test gate (§5B) before trusting CI.
- **create-dmg flakiness** (AppleScript) → retry/tolerate nonzero with output check.
- **Rename breakage** (XcodeGen target/scheme/probe paths, `@main` type) → `xcodegen generate`
  + a CLI build must pass before touching signing.
- **Keychain import non-interactive** → `set-key-partition-list` (in §5C) is the known fix.
- **Data path rename** (keychain service / app-support dir) → documented, not silently migrated.
- **`.p12` holds an extra Apple Development identity** → harmless; codesign selects Developer ID by name.

## 7. Out of scope (now)
- Mac App Store build; Sparkle/auto-update; branded DMG background art; GitHub repo rename;
  renaming the bundled keychain data migration.

## 8. Acceptance criteria
1. `xcodegen generate` + Release build succeed under the **Clipmunk** name/bundle ID.
2. Local hardened+signed build **launches and completes one real generation** (entitlements finalized).
3. Pushing a `v*` tag produces a GitHub Release with **`Clipmunk.dmg`** that is signed + notarized + stapled.
4. `spctl` reports **"accepted … Notarized Developer ID"**; a fresh download on another Mac opens with **no Gatekeeper prompt**.
5. App icon shows correctly (Dock/Finder/Spotlight); README documents RAM/disk requirements; `NOTICE` retains Shortcast attribution.
6. `scripts/dev-build.sh` produces a runnable local build.
