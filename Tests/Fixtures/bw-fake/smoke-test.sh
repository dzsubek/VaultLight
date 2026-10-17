#!/usr/bin/env bash
# Smoke test for the fake bw CLI. Runs it the way the wrapper must: minimal env, no shell tricks.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bw="$here/bw"
data="$(mktemp -d)"
trap 'rm -rf "$data"' EXIT

pass=0
run() { # run <expected-exit> <extra env...> -- <args...>
  local expected=$1; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  set +e
  out=$(env -i HOME="$HOME" PATH="/usr/bin:/bin" BITWARDENCLI_APPDATA_DIR="$data" "${envs[@]}" "$bw" "$@" 2>&1)
  code=$?
  set -e
  if [ "$code" != "$expected" ]; then
    echo "FAIL: bw $* → exit $code (expected $expected): $out"; exit 1
  fi
  pass=$((pass + 1))
}

PW="correct horse battery staple"
SESSION="fake-session-key-0123456789abcdef"

run 0 -- --version
run 98 -- status                                          # --nointeraction is required
run 0 -- status --nointeraction
echo "$out" | grep -q '"status": "unauthenticated"' || { echo "FAIL: expected unauthenticated"; exit 1; }
run 0 -- config server https://vault.example.test --nointeraction
run 1 BW_CLIENTID=wrong BW_CLIENTSECRET=wrong -- login --apikey --nointeraction
run 0 BW_CLIENTID=user.00000000-fake-client-id BW_CLIENTSECRET=fake-client-secret-abcdef -- login --apikey --nointeraction
run 99 -- unlock "$PW" --nointeraction                    # secret in argv
run 1 VL_PW=wrong -- unlock --passwordenv VL_PW --raw --nointeraction
run 0 VL_PW="$PW" -- unlock --passwordenv VL_PW --raw --nointeraction
[ "$out" = "$SESSION" ] || { echo "FAIL: unlock --raw printed '$out'"; exit 1; }
run 1 -- list items --nointeraction                       # no BW_SESSION → locked
run 0 BW_SESSION="$SESSION" -- list items --nointeraction
count=$(echo "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$count" = "15" ] || { echo "FAIL: expected 15 items, got $count"; exit 1; }
id=$(echo "$out" | python3 -c 'import json,sys; print(next(i["id"] for i in json.load(sys.stdin) if i["name"]=="GitHub"))')
run 99 -- list items --session "$SESSION" --nointeraction # session in argv
run 0 BW_SESSION="$SESSION" -- get password "$id" --raw --nointeraction
[ "$out" = "fake-pw-github-7Qx!" ] || { echo "FAIL: get password printed '$out'"; exit 1; }
run 0 BW_SESSION="$SESSION" -- get totp "$id" --raw --nointeraction
run 0 BW_SESSION="$SESSION" -- sync --nointeraction
run 0 -- lock --nointeraction
run 1 BW_SESSION="$SESSION" -- list items --nointeraction  # locked again

# exit 97: no BITWARDENCLI_APPDATA_DIR
set +e; env -i PATH=/usr/bin:/bin "$bw" status --nointeraction >/dev/null 2>&1; code=$?; set -e
[ "$code" = "97" ] || { echo "FAIL: missing data dir → exit $code (expected 97)"; exit 1; }
pass=$((pass + 1))

lines=$(wc -l <"$data/fake-calls.jsonl" | tr -d ' ')
[ "$lines" -gt 10 ] || { echo "FAIL: call log has $lines lines"; exit 1; }

echo "fake bw smoke test: $pass checks passed"
