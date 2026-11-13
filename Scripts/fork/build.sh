#!/usr/bin/env bash
# Build, sign and notarize FreeSnitch under YOUR Apple Developer team.
#
# Upstream's identifiers (team BHAF4L4726, io.isaaclins.freesnitch) are tied to
# upstream's Developer ID and provisioning profiles, so a build signed with any
# other certificate cannot run. Rather than fork every source file, this script
# copies the tree to build/fork/src, rewrites the identifiers in the copy,
# fetches matching profiles through the App Store Connect API, and builds the
# firewall flavour there. The checked-in sources stay identical to upstream.
#
#   Scripts/fork/build.sh            # -> dist/FreeSnitch.app (signed, notarized, stapled)
#   SKIP_NOTARIZE=1 Scripts/fork/build.sh
#
# Reads .env at the repo root:
#   APPLE_API_KEY_ID, APPLE_API_ISSUER, APPLE_API_KEY_PATH  (App Store Connect API key)
#   FORK_BUNDLE_PREFIX   default com.yazinsai.freesnitch
#   CODESIGN_IDENTITY    default: first "Developer ID Application" in the keychain
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PREFIX="${FORK_BUNDLE_PREFIX:-com.yazinsai.freesnitch}"
SIGN_ID="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[[ -n "$SIGN_ID" ]] || die "no Developer ID Application identity in the keychain"
TEAM="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$SIGN_ID")"
[[ -n "$TEAM" ]] || die "could not read the team ID from: $SIGN_ID"
APP_PROFILE_NAME="FreeSnitch Fork App DeveloperID"
NETEXT_PROFILE_NAME="FreeSnitch Fork NetExt DeveloperID"

WORK="$ROOT/build/fork"
SRC="$WORK/src"
DERIVED="$WORK/DerivedData"
OUT="$ROOT/dist"
export CLANG_MODULE_CACHE_PATH="$WORK/ModuleCache"

printf '=== FreeSnitch fork build\n  identity: %s\n  team:     %s\n  bundle:   %s\n' "$SIGN_ID" "$TEAM" "$PREFIX"

# 1. A rewritten copy of the tree.
rm -rf "$SRC"; mkdir -p "$SRC"
rsync -a --exclude .git --exclude build --exclude dist --exclude '*.xcodeproj' --exclude Profiles "$ROOT/" "$SRC/"
UPSTREAM_SIGN='Developer ID Application: isaac lins (BHAF4L4726)'
export UPSTREAM_SIGN SIGN_ID TEAM PREFIX APP_PROFILE_NAME NETEXT_PROFILE_NAME
find "$SRC/Sources" "$SRC/project.yml" "$SRC/project-netext.yml" -type f \
  \( -name '*.swift' -o -name '*.plist' -o -name '*.entitlements' -o -name '*.yml' \) -print0 |
  xargs -0 perl -pi -e '
    s/\Q$ENV{UPSTREAM_SIGN}\E/$ENV{SIGN_ID}/g;
    s/BHAF4L4726/$ENV{TEAM}/g;
    s/io\.isaaclins\.freesnitch/$ENV{PREFIX}/g;
    s/FreeSnitch App DeveloperID 2026/$ENV{APP_PROFILE_NAME}/g;
    s/FreeSnitch NetExt DeveloperID 2026/$ENV{NETEXT_PROFILE_NAME}/g;
    # Upstream releases are signed by another team and must never replace
    # this build, so the update feed is turned off.
    s{(SUFeedURL:\s*).*}{$1"https://github.com/yazinsai/freesnitch/releases"};
    s/(SUEnableAutomaticChecks:\s*)true/$1false/;
  '
if grep -rIn "BHAF4L4726\|io\.isaaclins\.freesnitch" "$SRC/Sources" "$SRC/project.yml" "$SRC/project-netext.yml"; then
  die "upstream identifiers survived the rewrite"
fi

# 2. Provisioning profiles for the rewritten bundle IDs.
node "$ROOT/Scripts/fork/profiles.mjs" "$PREFIX" "$SRC/Profiles"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"
for p in "$SRC/Profiles/"*.provisionprofile; do
  uuid="$(security cms -D -i "$p" 2>/dev/null | plutil -extract UUID raw -o - -)"
  cp -f "$p" "$PROFILE_DIR/$uuid.provisionprofile"
done

# 3. Build the firewall flavour.
(cd "$SRC" && xcodegen generate --spec project-netext.yml >/dev/null)
mkdir -p "$WORK"
LOG="$WORK/xcodebuild.log"
printf 'Building (log: %s)...\n' "$LOG"
if ! xcodebuild -project "$SRC/FreeSnitch.xcodeproj" -scheme FreeSnitch -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
    ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_ID" DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS='--timestamp --options=runtime' \
    clean build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20 >&2 || tail -50 "$LOG" >&2
  die "xcodebuild failed"
fi

APP="$DERIVED/Build/Products/Release/FreeSnitch.app"
[[ -d "$APP" ]] || die "no app at $APP"
NETEXT="$APP/Contents/Library/SystemExtensions/$PREFIX.netext.systemextension"
[[ -d "$NETEXT" ]] || die "system extension missing: $NETEXT"
[[ -f "$APP/Contents/embedded.provisionprofile" && -f "$NETEXT/Contents/embedded.provisionprofile" ]] ||
  die "a provisioning profile was not embedded"

# 4. Re-sign nested code inside-out (same order as Scripts/release.sh).
sign() { codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SV="$(cd "$SPARKLE/Versions/Current" && pwd -P)"
sign "$SV/XPCServices/Downloader.xpc"
sign "$SV/XPCServices/Installer.xpc"
sign "$SV/Updater.app"
sign "$SV/Autoupdate"
sign "$SPARKLE"
sign --entitlements "$SRC/Sources/Helper/Helper.entitlements" "$APP/Contents/MacOS/FreeSnitchHelper"
[[ -f "$APP/Contents/Helpers/freesnitch" ]] && sign --identifier "$PREFIX.cli" "$APP/Contents/Helpers/freesnitch"
sign --entitlements "$SRC/Sources/NetExt/NetExt.entitlements" "$NETEXT"
sign --entitlements "$SRC/Sources/GUI/FreeSnitch-netext.entitlements" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

# 5. Notarize and staple.
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  KEY="${APPLE_API_KEY_PATH/#\~/$HOME}"
  [[ -d "$KEY" ]] && KEY="$KEY/AuthKey_${APPLE_API_KEY_ID}.p8"
  ZIP="$WORK/FreeSnitch-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --key "$KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

mkdir -p "$OUT"
rm -rf "$OUT/FreeSnitch.app"
ditto "$APP" "$OUT/FreeSnitch.app"
printf '=== Built %s\n' "$OUT/FreeSnitch.app"
