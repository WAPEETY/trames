#!/usr/bin/env bash
# Derive versionName/versionCode from git; appends them to $GITHUB_ENV.
#   tag v1.2.0-beta.1 -> name 1.2.0-beta.1, channel beta
#   untagged commit   -> name from `git describe` (e.g. 1.2.0-beta.1-5-gabc1234), channel dev
# versionCode = commits * 10 + channel rank, so it always grows along main and
# promoting the same commit (alpha -> beta -> stable) still counts as an update.
set -euo pipefail
ref_type=${1:-branch} ref_name=${2:-}
count=$(git rev-list --count HEAD)
if [[ $ref_type == tag ]]; then
  name=${ref_name#v}
  case $name in
    *-alpha.*) channel=alpha rank=1 ;;
    *-beta.*)  channel=beta rank=2 ;;
    *-*)       echo "unsupported tag $ref_name" >&2; exit 1 ;;
    *)         channel=stable rank=3 ;;
  esac
else
  name=$(git describe --tags --match 'v*' 2>/dev/null || echo "v0.0.0-$count-g$(git rev-parse --short HEAD)")
  name=${name#v} channel=dev rank=0
fi
code=$((count * 10 + rank))
echo "version $name ($code), channel $channel"
{
  echo "VERSION_NAME=$name"
  echo "VERSION_CODE=$code"
  echo "CHANNEL=$channel"
} >> "${GITHUB_ENV:-/dev/null}"
