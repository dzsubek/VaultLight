#!/usr/bin/env bash
# Renders packaging/vaultlight.rb with a release's version and checksum.
#
# Usage: scripts/render-cask.sh VERSION SHA256 [OUT]     (stdout when OUT is omitted)
set -euo pipefail

usage() { echo "usage: $0 VERSION SHA256 [OUT]" >&2; exit 2; }

[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || usage
version=$1
sha=$2
out=${3:-}

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must look like 1.2.3" >&2; usage; }
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "SHA256 must be 64 lowercase hex characters" >&2; usage; }

template="$(dirname "$0")/../packaging/vaultlight.rb"
rendered=$(sed -E \
  -e "s/^(  version )\"[^\"]*\"$/\1\"$version\"/" \
  -e "s/^(  sha256 )\"[^\"]*\"$/\1\"$sha\"/" \
  "$template")

# The template must still have both lines, or the cask would ship the wrong version.
grep -q "^  version \"$version\"\$" <<<"$rendered" || { echo "template has no version line" >&2; exit 1; }
grep -q "^  sha256 \"$sha\"\$" <<<"$rendered" || { echo "template has no sha256 line" >&2; exit 1; }

if [ -n "$out" ]; then
  printf '%s\n' "$rendered" >"$out"
else
  printf '%s\n' "$rendered"
fi
