#!/usr/bin/env bash
# Builds, signs with Developer ID, notarizes and staples VaultLight, then zips it for the Homebrew cask.
#
# Usage: scripts/release.sh --version X.Y.Z --notary-profile NAME [--build-number N] [--output DIR]
#        scripts/release.sh --self-test      check the argument validation (runs no build or notarization)
#        scripts/release.sh -h
#
# --notary-profile is the name of a `xcrun notarytool store-credentials` keychain profile.
# Environment (all optional):
#   NOTARY_KEYCHAIN                           keychain holding the profile (passed to notarytool --keychain)
#   ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID   App Store Connect API key for xcodebuild; all three or none
#   VL_TEAM_ID, VL_BUNDLE_ID                  override what Configs/Local.xcconfig supplies
#
# Exit codes: 0 done, 1 a step failed, 2 bad arguments (nothing was run).
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: scripts/release.sh --version X.Y.Z --notary-profile NAME [--build-number N] [--output DIR]
       scripts/release.sh --self-test
       scripts/release.sh -h
USAGE
}

bad_usage() {
  echo "error: $*" >&2
  usage
  exit 2
}

# validate_args: exits 2 on the first problem. Runs before any command with side effects.
validate_args() {
  [ -n "$version" ] || bad_usage "--version is required"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || bad_usage "--version must look like 1.2.3"
  [ -n "$profile" ] || bad_usage "--notary-profile is required"
  [[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || bad_usage "--notary-profile may only contain letters, digits, '.', '_' and '-'"
  if [ -n "$build_number" ]; then
    [[ "$build_number" =~ ^[0-9]+$ ]] || bad_usage "--build-number must be a whole number"
  fi
  [ -n "$output" ] || bad_usage "--output must not be empty"

  local asc_set=0
  [ -z "${ASC_KEY_PATH:-}" ] || asc_set=$((asc_set + 1))
  [ -z "${ASC_KEY_ID:-}" ] || asc_set=$((asc_set + 1))
  [ -z "${ASC_ISSUER_ID:-}" ] || asc_set=$((asc_set + 1))
  if [ "$asc_set" -ne 0 ] && [ "$asc_set" -ne 3 ]; then
    bad_usage "ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID must be set together or not at all"
  fi
  if [ "$asc_set" -eq 3 ] && [ ! -f "$ASC_KEY_PATH" ]; then
    bad_usage "ASC_KEY_PATH does not name a file"
  fi
  if [ -n "${VL_TEAM_ID:-}" ]; then
    [[ "$VL_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || bad_usage "VL_TEAM_ID must be a 10-character Team ID"
  fi
  if [ -n "${VL_BUNDLE_ID:-}" ]; then
    [[ "$VL_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || bad_usage "VL_BUNDLE_ID must be a reverse-DNS identifier"
  fi
}

fail() { echo "error: $*" >&2; exit 1; }

# resolve_identity SETTINGS CASK_FILE: prints "TEAM BUNDLE_ID" from the Release build settings text and
# fails unless the team is set and the bundle ID is the one the cask quits (its `uninstall quit:` line).
resolve_identity() {
  local settings=$1 cask=$2 team bundle cask_bundle
  team=$(sed -n -E 's/^[[:space:]]*DEVELOPMENT_TEAM = (.*)$/\1/p' <<<"$settings" | head -n 1)
  bundle=$(sed -n -E 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = (.*)$/\1/p' <<<"$settings" | head -n 1)
  cask_bundle=$(sed -n -E 's/^[[:space:]]*uninstall quit: "([^"]+)".*$/\1/p' "$cask" | head -n 1)
  [ -n "$team" ] || fail "DEVELOPMENT_TEAM is empty: set VL_TEAM_ID or Configs/Local.xcconfig"
  [ -n "$bundle" ] || fail "PRODUCT_BUNDLE_IDENTIFIER is empty: set VL_BUNDLE_ID or Configs/Local.xcconfig"
  [ -n "$cask_bundle" ] || fail "no 'uninstall quit:' bundle ID found in $cask"
  [ "$bundle" = "$cask_bundle" ] || fail "the bundle ID is '$bundle' but the cask quits '$cask_bundle'; the cask and the app must agree"
  echo "$team $bundle"
}

# self_test: runs this script with bad arguments under stubbed tools and expects exit 2 and no tool call.
self_test() {
  local tmp stubs marker failures=0 script
  script=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  stubs="$tmp/stubs"
  marker="$tmp/tool-was-called"
  mkdir "$stubs"
  for tool in make xcodebuild xcrun codesign ditto spctl shasum plutil; do
    printf '#!/bin/sh\necho "%s" >> "%s"\nexit 0\n' "$tool" "$marker" >"$stubs/$tool"
    chmod +x "$stubs/$tool"
  done
  printf 'not a real key\n' >"$tmp/key.p8"

  run() { # EXPECTED_STATUS NAME [VAR=value ...] -- ARGS...
    local expected=$1 name=$2 status=0
    shift 2
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    env -i PATH="$stubs:/usr/bin:/bin" HOME="$HOME" ${envs[@]+"${envs[@]}"} \
      "$script" "$@" >/dev/null 2>&1 || status=$?
    if [ -e "$marker" ]; then
      echo "FAIL $name: a build tool was started: $(tr '\n' ' ' <"$marker")"; failures=$((failures + 1)); rm -f "$marker"
    elif [ "$status" -ne "$expected" ]; then
      echo "FAIL $name: exit $status, expected $expected"; failures=$((failures + 1))
    else
      echo "ok   $name"
    fi
  }

  run 2 "no arguments" -- 
  run 2 "missing version" -- --notary-profile p
  run 2 "missing profile" -- --version 1.2.3
  run 2 "version without patch" -- --version 1.2 --notary-profile p
  run 2 "version with v prefix" -- --version v1.2.3 --notary-profile p
  run 2 "version with suffix" -- --version 1.2.3-beta --notary-profile p
  run 2 "empty version" -- --version "" --notary-profile p
  run 2 "profile starting with a dash" -- --version 1.2.3 --notary-profile -x
  run 2 "profile with a space" -- --version 1.2.3 --notary-profile "a b"
  run 2 "bad build number" -- --version 1.2.3 --notary-profile p --build-number x1
  run 2 "empty output" -- --version 1.2.3 --notary-profile p --output ""
  run 2 "option without a value" -- --version 1.2.3 --notary-profile
  run 2 "unknown option" -- --version 1.2.3 --notary-profile p --frobnicate
  run 2 "unexpected argument" -- --version 1.2.3 --notary-profile p extra
  run 2 "only ASC_KEY_PATH" "ASC_KEY_PATH=$tmp/key.p8" -- --version 1.2.3 --notary-profile p
  run 2 "only ASC_KEY_ID" "ASC_KEY_ID=ABC123" -- --version 1.2.3 --notary-profile p
  run 2 "ASC_KEY_PATH missing" "ASC_KEY_ID=ABC123" "ASC_ISSUER_ID=x" -- --version 1.2.3 --notary-profile p
  run 2 "ASC key file missing" "ASC_KEY_PATH=$tmp/nope.p8" "ASC_KEY_ID=ABC123" "ASC_ISSUER_ID=x" -- --version 1.2.3 --notary-profile p
  run 2 "bad team id" "VL_TEAM_ID=abc" -- --version 1.2.3 --notary-profile p
  run 2 "bad bundle id" "VL_BUNDLE_ID=nodots" -- --version 1.2.3 --notary-profile p
  run 0 "help" -- -h
  run 0 "valid arguments" -- --validate-only --version 1.2.3 --notary-profile p
  run 0 "valid arguments with every option" "ASC_KEY_PATH=$tmp/key.p8" "ASC_KEY_ID=ABC123" "ASC_ISSUER_ID=x" \
    "VL_TEAM_ID=ABCDE12345" "VL_BUNDLE_ID=com.example.app" -- \
    --validate-only --version 1.2.3 --notary-profile p --build-number 7 --output "$tmp/out"

  printf '  uninstall quit: "com.example.app"\n' >"$tmp/cask.rb"
  identity() { # NAME EXPECTED_OK TEAM BUNDLE
    local settings out status=0
    settings=$(printf '    DEVELOPMENT_TEAM = %s\n    PRODUCT_BUNDLE_IDENTIFIER = %s\n' "$3" "$4")
    out=$( (resolve_identity "$settings" "$tmp/cask.rb") 2>/dev/null) || status=$?
    if [ "$2" = ok ] && { [ "$status" -ne 0 ] || [ "$out" != "$3 $4" ]; }; then
      echo "FAIL $1: expected '$3 $4'"; failures=$((failures + 1))
    elif [ "$2" = reject ] && [ "$status" -eq 0 ]; then
      echo "FAIL $1: expected a rejection"; failures=$((failures + 1))
    else
      echo "ok   $1"
    fi
  }
  identity "identity matching the cask" ok ABCDE12345 com.example.app
  identity "empty team" reject "" com.example.app
  identity "bundle ID differing from the cask" reject ABCDE12345 com.other.app
  identity "empty bundle ID" reject ABCDE12345 ""

  if [ "$failures" -ne 0 ]; then
    echo "$failures self-test case(s) failed" >&2
    return 1
  fi
  echo "self-test passed"
}

version=""
profile=""
build_number=""
output=".build/release"
validate_only=0
want_self_test=0

while [ "$#" -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --self-test) want_self_test=1; shift ;;
    --validate-only) validate_only=1; shift ;;
    --version|--notary-profile|--build-number|--output)
      [ "$#" -ge 2 ] || bad_usage "$1 needs a value"
      case $1 in
        --version) version=$2 ;;
        --notary-profile) profile=$2 ;;
        --build-number) build_number=$2 ;;
        --output) output=$2 ;;
      esac
      shift 2 ;;
    *) bad_usage "unexpected argument: $1" ;;
  esac
done

if [ "$want_self_test" -eq 1 ]; then
  self_test
  exit $?
fi

validate_args

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
[ -n "$build_number" ] || build_number=$(git rev-list --count HEAD)

if [ "$validate_only" -eq 1 ]; then
  echo "arguments OK: version $version, build $build_number"
  exit 0
fi

case $output in /*) ;; *) output="$PWD/$output" ;; esac

step() { echo; echo "==> $*"; }

archive="$output/VaultLight.xcarchive"
export_dir="$output/export"
app="$export_dir/VaultLight.app"
notarize_zip="$output/VaultLight-$version-notarize.zip"
final_zip="$output/VaultLight-$version.zip"

mkdir -p "$output"
rm -rf "$archive" "$export_dir" "$notarize_zip" "$final_zip" "$final_zip.sha256"

asc_args=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  asc_args=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
overrides=("MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build_number")
[ -z "${VL_TEAM_ID:-}" ] || overrides+=("VL_TEAM_ID=$VL_TEAM_ID")
[ -z "${VL_BUNDLE_ID:-}" ] || overrides+=("VL_BUNDLE_ID=$VL_BUNDLE_ID")

step "Generate the Xcode project"
make gen

step "Resolve the signing identity"
settings=$(xcodebuild -project VaultLight.xcodeproj -scheme VaultLight -configuration Release \
  "${overrides[@]}" -showBuildSettings 2>/dev/null)
read -r team bundle <<<"$(resolve_identity "$settings" packaging/vaultlight.rb)"
echo "team $team, bundle ID $bundle"

step "Archive $version ($build_number)"
xcodebuild archive \
  -project VaultLight.xcodeproj -scheme VaultLight -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" -derivedDataPath "$output/DerivedData" \
  -allowProvisioningUpdates ${asc_args[@]+"${asc_args[@]}"} \
  "${overrides[@]}"

step "Export with Developer ID"
export_options="$output/ExportOptions.plist"
cp packaging/ExportOptions.plist "$export_options"
if [ -n "${VL_TEAM_ID:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :teamID string $VL_TEAM_ID" "$export_options"
fi
xcodebuild -exportArchive \
  -archivePath "$archive" -exportPath "$export_dir" -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates ${asc_args[@]+"${asc_args[@]}"}
[ -d "$app" ] || fail "the export has no VaultLight.app"

step "Verify the signature"
codesign --verify --deep --strict --verbose=2 "$app"
details=$(codesign -dvv "$app" 2>&1)
grep -q '^Authority=Developer ID Application' <<<"$details" || fail "the app is not signed by a Developer ID Application certificate"
grep -q "^TeamIdentifier=$team\$" <<<"$details" || fail "the signature's TeamIdentifier is not $team"
grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details" || fail "Hardened Runtime is not enabled in the signature"
entitlements="$output/signed-entitlements.plist"
codesign -d --entitlements - --xml "$app" >"$entitlements" 2>/dev/null
group=$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$entitlements" 2>/dev/null || true)
[ "$group" = "$team.$bundle" ] || fail "keychain-access-groups[0] is '${group:-missing}', expected $team.$bundle"
for key in com.apple.security.get-task-allow com.apple.security.app-sandbox; do
  if /usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" >/dev/null 2>&1; then
    fail "the signed app has the $key entitlement"
  fi
done
plist="$app/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "$bundle" ] || fail "CFBundleIdentifier is not $bundle"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$version" ] || fail "CFBundleShortVersionString is not $version"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$build_number" ] || fail "CFBundleVersion is not $build_number"
profile_file="$app/Contents/embedded.provisionprofile"
[ -f "$profile_file" ] || fail "the app has no embedded provisioning profile"
profile_plist="$output/embedded-profile.plist"
security cms -D -i "$profile_file" >"$profile_plist" || fail "the embedded provisioning profile could not be decoded"
[ "$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist" 2>/dev/null || true)" = "$team" ] || fail "the provisioning profile belongs to another team"
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$profile_plist" 2>/dev/null || true)" = "true" ] || fail "the provisioning profile is not a Developer ID profile (ProvisionsAllDevices is not true)"
/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups' "$profile_plist" >/dev/null 2>&1 || fail "the provisioning profile does not grant keychain-access-groups"

step "Notarize"
ditto -c -k --keepParent "$app" "$notarize_zip"
notary_args=(--keychain-profile "$profile")
[ -z "${NOTARY_KEYCHAIN:-}" ] || notary_args+=(--keychain "$NOTARY_KEYCHAIN")
result="$output/notary-result.json"
xcrun notarytool submit "$notarize_zip" "${notary_args[@]}" --wait --output-format json >"$result" || true
status=$(plutil -extract status raw -o - "$result" 2>/dev/null || echo unknown)
if [ "$status" != "Accepted" ]; then
  id=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
  if [ -n "$id" ]; then
    xcrun notarytool log "$id" "${notary_args[@]}" >&2 || true
  fi
  fail "notarization status is '$status', expected Accepted"
fi

step "Staple and assess"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
assessment=$(spctl --assess --type execute -vv "$app" 2>&1) || { echo "$assessment" >&2; fail "Gatekeeper rejects the app"; }
echo "$assessment"
grep -q '^source=Notarized Developer ID' <<<"$assessment" || fail "Gatekeeper does not report source=Notarized Developer ID"

step "Create the release archive"
ditto -c -k --keepParent "$app" "$final_zip"
rm -f "$notarize_zip"
(cd "$output" && shasum -a 256 "VaultLight-$version.zip" >"VaultLight-$version.zip.sha256")

echo
echo "Release archive: $final_zip"
cat "$final_zip.sha256"
