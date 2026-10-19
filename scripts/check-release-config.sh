#!/usr/bin/env bash
# Checks that the Release configuration keeps the signing properties spec 9.1 and 11.2 require:
# Hardened Runtime on, no base entitlements injected (no get-task-allow), no App Sandbox,
# and the keychain-access-groups entitlement present.
#
# Usage:   scripts/check-release-config.sh              check the real project (needs `make gen`)
#          scripts/check-release-config.sh --self-test  prove each rule rejects a broken copy
# No signing identity is needed: it only reads build settings and the entitlements file.
set -euo pipefail

# evaluate SETTINGS_FILE ENTITLEMENTS_FILE: prints one line per violated rule; returns 1 if any.
evaluate() {
  local settings=$1 entitlements=$2 failed=0 value

  setting() { sed -n -E "s/^[[:space:]]*$1 = (.*)$/\1/p" "$settings" | head -n 1; }

  value=$(setting ENABLE_HARDENED_RUNTIME)
  if [ "$value" != "YES" ]; then
    echo "FAIL: ENABLE_HARDENED_RUNTIME is '${value:-unset}', expected YES (Hardened Runtime is mandatory for notarization)"
    failed=1
  fi
  value=$(setting CODE_SIGN_INJECT_BASE_ENTITLEMENTS)
  if [ "$value" != "NO" ]; then
    echo "FAIL: CODE_SIGN_INJECT_BASE_ENTITLEMENTS is '${value:-unset}', expected NO (otherwise Xcode adds get-task-allow)"
    failed=1
  fi
  value=$(setting ENABLE_APP_SANDBOX)
  if [ "$value" = "YES" ]; then
    echo "FAIL: ENABLE_APP_SANDBOX is YES; the sandbox would block starting bw (spec 11.2)"
    failed=1
  fi

  if [ ! -f "$entitlements" ]; then
    echo "FAIL: entitlements file '$entitlements' not found"
    return 1
  fi
  if ! /usr/libexec/PlistBuddy -c "Print :keychain-access-groups" "$entitlements" >/dev/null 2>&1; then
    echo "FAIL: entitlements lack keychain-access-groups (the data-protection keychain needs it)"
    failed=1
  fi
  for key in com.apple.security.app-sandbox com.apple.security.get-task-allow; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" >/dev/null 2>&1; then
      echo "FAIL: entitlements contain $key"
      failed=1
    fi
  done
  return "$failed"
}

check_project() {
  cd "$(dirname "$0")/.."
  [ -d VaultLight.xcodeproj ] || { echo "VaultLight.xcodeproj is missing: run make gen" >&2; return 1; }
  local tmp settings srcroot entitlements
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  settings="$tmp/settings.txt"
  xcodebuild -project VaultLight.xcodeproj -scheme VaultLight -configuration Release \
    -showBuildSettings >"$settings" 2>/dev/null
  srcroot=$(sed -n -E 's/^[[:space:]]*SRCROOT = (.*)$/\1/p' "$settings" | head -n 1)
  entitlements=$(sed -n -E 's/^[[:space:]]*CODE_SIGN_ENTITLEMENTS = (.*)$/\1/p' "$settings" | head -n 1)
  if [ -z "$entitlements" ]; then
    echo "FAIL: CODE_SIGN_ENTITLEMENTS is not set for Release" >&2
    return 1
  fi
  case $entitlements in /*) ;; *) entitlements="$srcroot/$entitlements" ;; esac
  if evaluate "$settings" "$entitlements"; then
    echo "Release config OK: Hardened Runtime, no injected get-task-allow, no sandbox, keychain-access-groups present"
  else
    return 1
  fi
}

write_good_inputs() { # DIR
  cat >"$1/settings.txt" <<'SETTINGS'
    ENABLE_HARDENED_RUNTIME = YES
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO
    ENABLE_APP_SANDBOX = NO
SETTINGS
  cat >"$1/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	</array>
</dict>
</plist>
PLIST
}

self_test() {
  local tmp failures=0 name
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  expect_pass() { # NAME DIR
    if evaluate "$2/settings.txt" "$2/entitlements.plist" >/dev/null; then
      echo "ok   $1"
    else
      echo "FAIL $1: expected the check to pass"; failures=$((failures + 1))
    fi
  }
  expect_reject() { # NAME DIR
    local out
    if out=$(evaluate "$2/settings.txt" "$2/entitlements.plist"); then
      echo "FAIL $1: expected the check to reject this copy"; failures=$((failures + 1))
    elif [ -z "$out" ]; then
      echo "FAIL $1: rejected without a message"; failures=$((failures + 1))
    else
      echo "ok   $1"
    fi
  }

  mkdir "$tmp/good"; write_good_inputs "$tmp/good"
  expect_pass "good copy passes" "$tmp/good"

  name="hardened runtime off"; mkdir "$tmp/1"; write_good_inputs "$tmp/1"
  sed -i '' 's/ENABLE_HARDENED_RUNTIME = YES/ENABLE_HARDENED_RUNTIME = NO/' "$tmp/1/settings.txt"
  expect_reject "$name" "$tmp/1"

  name="hardened runtime missing"; mkdir "$tmp/2"; write_good_inputs "$tmp/2"
  sed -i '' '/ENABLE_HARDENED_RUNTIME/d' "$tmp/2/settings.txt"
  expect_reject "$name" "$tmp/2"

  name="base entitlements injected"; mkdir "$tmp/3"; write_good_inputs "$tmp/3"
  sed -i '' 's/CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO/CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES/' "$tmp/3/settings.txt"
  expect_reject "$name" "$tmp/3"

  name="app sandbox build setting on"; mkdir "$tmp/4"; write_good_inputs "$tmp/4"
  sed -i '' 's/ENABLE_APP_SANDBOX = NO/ENABLE_APP_SANDBOX = YES/' "$tmp/4/settings.txt"
  expect_reject "$name" "$tmp/4"

  name="keychain-access-groups missing"; mkdir "$tmp/5"; write_good_inputs "$tmp/5"
  /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$tmp/5/entitlements.plist"
  expect_reject "$name" "$tmp/5"

  name="app-sandbox entitlement present"; mkdir "$tmp/6"; write_good_inputs "$tmp/6"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool true" "$tmp/6/entitlements.plist"
  expect_reject "$name" "$tmp/6"

  name="get-task-allow entitlement present"; mkdir "$tmp/7"; write_good_inputs "$tmp/7"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$tmp/7/entitlements.plist"
  expect_reject "$name" "$tmp/7"

  name="entitlements file missing"; mkdir "$tmp/8"; write_good_inputs "$tmp/8"
  rm "$tmp/8/entitlements.plist"
  expect_reject "$name" "$tmp/8"

  if [ "$failures" -ne 0 ]; then
    echo "$failures self-test case(s) failed" >&2
    return 1
  fi
  echo "self-test passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  "") check_project ;;
  *) echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
