# TestFlight upload (headless)

Build, sign, and upload NewsFirst to TestFlight from the command line — no Xcode GUI.
First proven 2026-07-06 for build 26 (v2.0.0).

> ⚠️ Only run on Tom's explicit OK — there's a daily upload limit, so batch changes.

## Normal upload

```bash
scripts/testflight/upload.sh
```

Bump the build number first if needed (`ios/project.yml` → `CURRENT_PROJECT_VERSION`, then it's
picked up on the next `xcodegen generate`, which `upload.sh` runs). Watch for `Upload succeeded`
in the output; the build then takes a few minutes of App Store Connect processing before it
appears in TestFlight.

## First-time / cert revoked

```bash
python3 scripts/testflight/create_signing.py
# then follow its printed instructions to set DIST_PROFILE_UUID / DIST_P12_PASS in secrets/asc.env
scripts/testflight/upload.sh
```

## Where things live

- **Secrets (outside git)** in the sibling `../secrets/`: `AuthKey_55V4X5BLCW.p8` (ASC API key),
  `asc.env` (ids + `DIST_P12_PASS`, `DIST_PROFILE_UUID`), `newsfirst_dist.p12` (Apple Distribution
  cert **+ private key**), `newsfirst_appstore.mobileprovision`.
- Build artifacts go in `ios/build/` (gitignored).

## The non-obvious gotchas (why this isn't just `xcodebuild`)

1. **App Manager ASC key can't cloud-sign, but CAN mint a cert via the raw API.** Xcode's
   `-allowProvisioningUpdates` cloud signing fails with *"Cloud signing permission error / No
   signing certificate 'iOS Distribution' found"*. Don't trust that as "can't sign" — generate
   the private key locally and `POST /v1/certificates` (type `DISTRIBUTION`) instead. That's what
   `create_signing.py` does.
2. **Legacy p12 required.** macOS `security import` rejects `cryptography`'s modern PKCS#12
   ("MAC verification failed"). The p12 must use `PBESv1SHA1And3KeyTripleDESCBC` + SHA1 HMAC.
3. **Throwaway keychain** (`ios/build/build.keychain`) is used so we never need the login-keychain
   password; the WWDR intermediate chains via the login keychain already in the search list.
4. **Manual signing** in ExportOptions (`signingCertificate: Apple Distribution`, profile by UUID)
   — automatic/cloud signing is what fails in step 1.

## Facts

- App `com.ant2555.newsfirst`, team `6W4ZBLPC9M` (Stewart Innovation Ltd), ASC App ID `6755879776`.
- Current artifacts: dist cert `85SVC7598H`, profile "NewsFirst AppStore CLI"
  uuid `ef66155c-739a-4dfe-9d19-314d1ff52cad`.
- Benign warning on upload: `onnxruntime.framework` (Kokoro TTS) has no dSYM → crash frames there
  won't symbolicate. Doesn't block the upload.
- Export compliance is pre-answered via `ITSAppUsesNonExemptEncryption=NO`.
