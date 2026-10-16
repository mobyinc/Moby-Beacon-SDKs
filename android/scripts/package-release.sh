#!/bin/bash
# Zips a published version of the Android SDK for a GitHub release.
#
#   android/scripts/package-release.sh 0.1.0
#
# Expects android/repo/com/mobyinc/moby-beacon/<version>/ to exist (run
# `./gradlew :moby-beacon:publish` first). Output:
#   android/build/release/moby-beacon-<version>/        a Maven repository folder
#       holding that one version, plus README.md and CHANGELOG.md
#   android/build/release/moby-beacon-<version>.zip     and its SHA-256
# Apps unzip the folder into their project and point Gradle at repo/ inside it.
set -euo pipefail

VERSION="${1:?usage: package-release.sh <version>}"
ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ANDROID_DIR/repo/com/mobyinc/moby-beacon/$VERSION"
if [ ! -f "$SRC/moby-beacon-$VERSION.aar" ]; then
  echo "no published $VERSION under android/repo; run ./gradlew :moby-beacon:publish first" >&2
  exit 1
fi

OUT="$ANDROID_DIR/build/release"
PKG="$OUT/moby-beacon-$VERSION"
rm -rf "$PKG" "$PKG.zip" "$PKG.zip.sha256"
mkdir -p "$PKG/repo/com/mobyinc/moby-beacon"
cp -R "$SRC" "$PKG/repo/com/mobyinc/moby-beacon/"
cp "$ANDROID_DIR/README.md" "$ANDROID_DIR/CHANGELOG.md" "$PKG/"

(cd "$OUT" && zip -qr "moby-beacon-$VERSION.zip" "moby-beacon-$VERSION")
(cd "$OUT" && shasum -a 256 "moby-beacon-$VERSION.zip" | tee "moby-beacon-$VERSION.zip.sha256")
echo "Built $PKG"
