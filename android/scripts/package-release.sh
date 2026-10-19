#!/bin/bash
# Zips a published version of the Android SDK for a GitHub release.
#
#   android/scripts/package-release.sh 0.1.0
#
# Expects android/moby-beacon/build/repo/com/mobyinc/moby-beacon/<version>/ to
# exist (run `./gradlew :moby-beacon:publish` first). Output:
#   android/build/release/moby-beacon-<version>/        a Maven repository folder
#       holding that one version, plus README.md and CHANGELOG.md
#   android/build/release/moby-beacon-<version>.zip     and its SHA-256
# Apps unzip the folder into their project and point Gradle at repo/ inside it.
set -euo pipefail

VERSION="${1:?usage: package-release.sh <version>}"
ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# The publication folder for an older version survives later publishes, so the
# version must be the one the sources declare, or a stale build would be shipped.
declare_version() { # $1 = file (relative to android/), $2 = fixed-string declaration
  if ! grep -qF -- "$2" "$ANDROID_DIR/$1"; then
    echo "$1 does not declare version $VERSION (expected: $2); bump it and publish first" >&2
    exit 1
  fi
}
declare_version moby-beacon/build.gradle "version = '$VERSION'"
declare_version moby-beacon/src/main/java/com/mobyinc/beacon/MobyBeacon.kt "const val VERSION = \"$VERSION\""
declare_version CHANGELOG.md "## $VERSION"
SRC="$ANDROID_DIR/moby-beacon/build/repo/com/mobyinc/moby-beacon/$VERSION"
# An AAR alone loses the dependency metadata Gradle needs. Check the complete
# publication before replacing an existing release folder or archive.
for artifact in "moby-beacon-$VERSION.aar" "moby-beacon-$VERSION.pom" \
    "moby-beacon-$VERSION.module" "moby-beacon-$VERSION-sources.jar"; do
  if [ ! -s "$SRC/$artifact" ]; then
    echo "missing or empty $SRC/$artifact; run ./gradlew :moby-beacon:publish first" >&2
    exit 1
  fi
done

OUT="$ANDROID_DIR/build/release"
PKG="$OUT/moby-beacon-$VERSION"
rm -rf "$PKG" "$PKG.zip" "$PKG.zip.sha256"
mkdir -p "$PKG/repo/com/mobyinc/moby-beacon"
cp -R "$SRC" "$PKG/repo/com/mobyinc/moby-beacon/"
cp "$ANDROID_DIR/README.md" "$ANDROID_DIR/CHANGELOG.md" "$ANDROID_DIR/../LICENSE" "$PKG/"

(cd "$OUT" && zip -qr "moby-beacon-$VERSION.zip" "moby-beacon-$VERSION")
(cd "$OUT" && shasum -a 256 "moby-beacon-$VERSION.zip" | tee "moby-beacon-$VERSION.zip.sha256")
echo "Built $PKG"
