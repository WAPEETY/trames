#!/usr/bin/env bash
# Write android/key.properties + keystore from secrets.
# Env: KEYSTORE_B64, KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD.
set -euo pipefail
for v in KEYSTORE_B64 KEYSTORE_PASSWORD KEY_ALIAS KEY_PASSWORD; do
  [[ -n ${!v:-} ]] || { echo "::error::secret for $v is not set (see RELEASING.md)"; exit 1; }
done
printf '%s' "$KEYSTORE_B64" | base64 -d > android/upload.jks
printf '%s\n' \
  "storeFile=upload.jks" \
  "storePassword=$KEYSTORE_PASSWORD" \
  "keyAlias=$KEY_ALIAS" \
  "keyPassword=$KEY_PASSWORD" > android/key.properties
