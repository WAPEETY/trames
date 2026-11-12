#!/usr/bin/env bash
# Extra tools the image lacks: JDK 21 (maplibre_gl targets Java 21; the image
# ships 17) and jq (release upload). Runs as root in the job container.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends openjdk-21-jdk-headless jq >/dev/null
jdk=$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")
case $jdk in *21*) ;; *) jdk=/usr/lib/jvm/java-21-openjdk-amd64 ;; esac
echo "JAVA_HOME=$jdk" >> "${GITHUB_ENV:-/dev/null}"
flutter config --jdk-dir "$jdk" >/dev/null
"$jdk/bin/java" -version 2>&1 | head -1
