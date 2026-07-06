#!/bin/bash
# Headless NewsFirst -> TestFlight upload (no Xcode GUI). Proven 2026-07-06 for build 26.
# Reuses the persisted Apple Distribution identity in ../secrets/newsfirst_dist.p12.
# First time (or if the cert is revoked / p12 missing): run create_signing.py first.
#
# Usage:  scripts/testflight/upload.sh
# Requires Tom's explicit OK before every run (daily upload limit; batch changes).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SECRETS="${SECRETS:-$(cd "$REPO_ROOT/.." && pwd)/secrets}"   # sibling of the repo, outside git

KEY="${ASC_KEY_PATH:-$SECRETS/AuthKey_55V4X5BLCW.p8}"
KID="${ASC_KEY_ID:-55V4X5BLCW}"
ISS="${ASC_ISSUER_ID:-fa6e71c1-7386-4d1c-aa19-6f0ae3b85c15}"
P12="${DIST_P12:-$SECRETS/newsfirst_dist.p12}"
P12_PASS="${DIST_P12_PASS:-tempPW123}"
PROFILE="${DIST_PROFILE:-$SECRETS/newsfirst_appstore.mobileprovision}"
PROFILE_UUID="${DIST_PROFILE_UUID:-ef66155c-739a-4dfe-9d19-314d1ff52cad}"
BUNDLE="com.ant2555.newsfirst"

WORK="$REPO_ROOT/ios/build"          # gitignored
KC="$WORK/build.keychain"; KCPW="buildpw"
ARCH="$WORK/NewsFirst.xcarchive"
mkdir -p "$WORK"

echo "== preflight =="
for f in "$KEY" "$P12" "$PROFILE"; do
  [ -f "$f" ] || { echo "MISSING: $f  -> run scripts/testflight/create_signing.py first"; exit 3; }
done

echo "== install provisioning profile =="
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$PROFILE" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"

echo "== throwaway keychain (avoids needing the login-keychain password) =="
rm -f "$KC" "$KC-db"
security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPW" "$KC"
# macOS security can't read cryptography's modern p12; create_signing.py writes a legacy (SHA1/3DES) one.
security import "$P12" -k "$KC" -P "$P12_PASS" -T /usr/bin/codesign -T /usr/bin/xcodebuild -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null 2>&1
ORIG=$(security list-keychains -d user | xargs); security list-keychains -d user -s "$KC" $ORIG
security find-identity -v -p codesigning "$KC" | grep -q "Apple Distribution" \
  || { echo "no valid Apple Distribution identity in keychain"; exit 4; }

echo "== regenerate project =="
command -v xcodegen >/dev/null && (cd "$REPO_ROOT/ios" && xcodegen generate >/dev/null)

echo "== archive (Release) =="
xcodebuild -project "$REPO_ROOT/ios/NewsFirst.xcodeproj" -scheme NewsFirst -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCH" clean archive \
  -allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$KID" -authenticationKeyIssuerID "$ISS" \
  2>&1 | tail -25
[ -d "$ARCH" ] || { echo "### ARCHIVE FAILED"; exit 5; }

echo "== ExportOptions (manual signing) =="
OPTS="$WORK/ExportOptions_manual.plist"
cat > "$OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>teamID</key><string>6W4ZBLPC9M</string>
<key>destination</key><string>upload</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Apple Distribution</string>
<key>provisioningProfiles</key><dict><key>$BUNDLE</key><string>$PROFILE_UUID</string></dict>
<key>uploadSymbols</key><true/>
</dict></plist>
PLIST

echo "== export + upload to App Store Connect =="
rm -rf "$WORK/export"
xcodebuild -exportArchive -archivePath "$ARCH" -exportPath "$WORK/export" -exportOptionsPlist "$OPTS" \
  -authenticationKeyPath "$KEY" -authenticationKeyID "$KID" -authenticationKeyIssuerID "$ISS" \
  2>&1 | tail -35
echo "### export rc=${PIPESTATUS[0]}  (look for 'Upload succeeded' above)"
