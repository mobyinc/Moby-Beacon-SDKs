#!/bin/bash
# Builds a distributable MobyBeacon.xcframework (iOS device + simulator) from the
# package in ios/, with library evolution enabled for compatible newer Swift
# toolchains. Build with the oldest Xcode version your client apps support.
#
#   ios/scripts/build-xcframework.sh 0.1.0
#
# Output: ios/build/xcframework/MobyBeacon-<version>/   a wrapper Swift package
#         (Package.swift + MobyBeacon.xcframework) that apps add as a local package,
#         ios/build/xcframework/MobyBeacon-<version>.zip and its SwiftPM checksum.
#
# Archiving a Swift package product only yields a framework when the product is
# dynamic, and that framework lacks its Modules/ and Headers/ folders. The script
# therefore builds from a temporary copy of the package marked `type: .dynamic`
# (the committed manifest stays static for source consumers) and copies the
# Swift module and generated Objective-C header into each slice itself.
set -euo pipefail

VERSION="${1:?usage: build-xcframework.sh <version>}"
IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$IOS_DIR/build/xcframework"
# The changelog ships inside the zip, so the version must have its entry.
grep -qF "## $VERSION" "$IOS_DIR/CHANGELOG.md" \
  || { echo "CHANGELOG.md has no '## $VERSION' section; add the release notes first" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Temporary copy of the package with a dynamic product and no test target.
#    The copy lives in a folder named MobyBeacon: xcodebuild takes the package
#    identity from the folder name and writes it into the framework's bundle
#    identifier and the -package-name flag of every .swiftinterface, so a
#    random mktemp name would leak into the shipped binary.
PKG_SRC="$WORK/MobyBeacon"
mkdir -p "$PKG_SRC"
cp -R "$IOS_DIR/Sources" "$PKG_SRC/"
sed -e 's/.library(name: "MobyBeacon", targets: \["MobyBeacon"\])/.library(name: "MobyBeacon", type: .dynamic, targets: ["MobyBeacon"])/' \
    -e '/testTarget/d' "$IOS_DIR/Package.swift" > "$PKG_SRC/Package.swift"
grep -q "type: .dynamic" "$PKG_SRC/Package.swift" || { echo "could not make the product dynamic" >&2; exit 1; }

# 2. One archive per platform, each with its own derived data.
archive() { # $1 = destination, $2 = name
  xcodebuild archive -quiet -scheme MobyBeacon -destination "$1" \
    -archivePath "$WORK/$2" -derivedDataPath "$WORK/dd-$2" \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO \
    PRODUCT_BUNDLE_IDENTIFIER=com.mobyinc.MobyBeacon \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION=1 \
    DYLIB_CURRENT_VERSION="$VERSION" DYLIB_COMPATIBILITY_VERSION="$VERSION"
}
# 3. Add the Swift module, the generated header and a module map to a slice.
assemble() { # $1 = name, $2 = platform (iphoneos | iphonesimulator)
  local fw="$WORK/$1.xcarchive/Products/usr/local/lib/MobyBeacon.framework"
  local ai="$WORK/dd-$1/Build/Intermediates.noindex/ArchiveIntermediates/MobyBeacon"
  mkdir -p "$fw/Modules" "$fw/Headers"
  cp -R "$ai/BuildProductsPath/Release-$2/MobyBeacon.swiftmodule" "$fw/Modules/"
  cp "$ai/IntermediateBuildFilesPath/GeneratedModuleMaps-$2/MobyBeacon-Swift.h" "$fw/Headers/"
  printf '#import <Foundation/Foundation.h>\n' > "$fw/Headers/MobyBeacon.h"
  cat > "$fw/Modules/module.modulemap" <<'MM'
framework module MobyBeacon {
  umbrella header "MobyBeacon.h"
  export *
  module * { export * }
}
module MobyBeacon.Swift {
  header "MobyBeacon-Swift.h"
  requires objc
}
MM
  echo "$fw"
}

cd "$PKG_SRC"
archive 'generic/platform=iOS' ios
archive 'generic/platform=iOS Simulator' sim
DEVICE_FW="$(assemble ios iphoneos)"
SIM_FW="$(assemble sim iphonesimulator)"

# 4. Merge into an XCFramework inside a wrapper package.
PKG="$OUT/MobyBeacon-$VERSION"
rm -rf "$PKG" "$PKG.zip" "$PKG.zip.checksum"
mkdir -p "$PKG"
xcodebuild -quiet -create-xcframework -framework "$DEVICE_FW" -framework "$SIM_FW" -output "$PKG/MobyBeacon.xcframework"
cat > "$PKG/Package.swift" <<'PS'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MobyBeacon",
    platforms: [.iOS(.v15)],
    products: [.library(name: "MobyBeacon", targets: ["MobyBeacon"])],
    targets: [.binaryTarget(name: "MobyBeacon", path: "MobyBeacon.xcframework")]
)
PS
cp "$IOS_DIR/README.md" "$IOS_DIR/CHANGELOG.md" "$IOS_DIR/../LICENSE" "$PKG/"
{
  xcodebuild -version
  xcrun swift --version
} > "$PKG/BUILD-INFO.txt"

# 5. Zip for a GitHub Release and print the checksum for a url-based binaryTarget.
(cd "$OUT" && ditto -c -k --keepParent --norsrc --noextattr "MobyBeacon-$VERSION" "MobyBeacon-$VERSION.zip")
(cd "$OUT" && swift package compute-checksum "MobyBeacon-$VERSION.zip" | tee "MobyBeacon-$VERSION.zip.checksum")
echo "Built $PKG"
