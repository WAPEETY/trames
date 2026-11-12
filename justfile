# Trames: common tasks. `just` lists them.

default:
    @just --list

# Offline tests (what CI runs)
test:
    flutter test --exclude-tags live

# Tests against the real transit services
test-live:
    flutter test --tags live

analyze:
    flutter analyze

# Release APK, signed with android/key.properties if present (debug key otherwise)
build-apk:
    flutter build apk --release

# Tag a release and push it; CI builds and publishes the APK.
# channel: alpha | beta | stable; bump: major | minor | patch | X.Y.Z (optional)
release channel bump="":
    tools/release.sh {{channel}} {{bump}}

# Tag current main as-is (e.g. promote the tested beta to stable)
promote channel bump="":
    tools/release.sh --promote {{channel}} {{bump}}

# Create the release keystore (once; back it up, losing it breaks app updates)
keystore:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ ! -e android/upload.jks ]] || { echo "android/upload.jks already exists"; exit 1; }
    keytool -genkeypair -v -keystore android/upload.jks -storetype JKS \
      -keyalg RSA -keysize 4096 -validity 10000 -alias upload
    echo "Now create android/key.properties and the Forgejo secrets (see RELEASING.md)."
