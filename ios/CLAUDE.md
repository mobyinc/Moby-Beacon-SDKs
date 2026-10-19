# MobyBeacon (iOS SDK)

Swift package for sending events from iOS study apps to the Moby Beacon API, callable from Swift and Objective-C. Port of the Flutter `moby_beacon` SDK; keep behavior aligned where the platforms allow. No third-party dependencies.

## Commands

- `swift test` — Run tests (macOS; the package lists macOS only so tests can run without a simulator)
- `xcrun swift build --triple arm64-apple-ios15.0-simulator --sdk $(xcrun --sdk iphonesimulator --show-sdk-path)` — Check that the package compiles for iOS
- `scripts/build-xcframework.sh <version>` — Build the release XCFramework and wrapper package into `build/xcframework/` (ignored)

## Layout

- `Sources/MobyBeacon/` — Implementation, one file per Flutter module:
  - `MobyBeacon.swift` — `MobyBeacon`: start/track/flush/dispose, the flush loop, 413 halving, timer, lifecycle handling, single live instance
  - `MobyBeaconConfig.swift` — `MobyBeaconConfig` and its argument checks; settings are snapshotted at `start`
  - `MobyBeaconSetupError.swift` — Errors thrown by `init` and `start`, with stable Objective-C domain and codes
  - `MobyBeaconError.swift`, `MobyBeaconEvent.swift` — Error and event types
  - `Validation.swift` — `validateEvent()` and `sanitizeEvent()`, mirrors the API's ingest rules
  - `Backoff.swift`, `RandomSource.swift` — `nextFlushDelay()` and its jitter seam
  - `EventStore.swift` — `EventStore`: FIFO queue with coalesced writes
  - `QueueStorage.swift` — `QueueStorage` protocol and `FileQueueStorage` (`queue.json`)
  - `Transport.swift`, `HTTPClient.swift` — HTTP send, status/`Retry-After` mapping, `URLSession` seam
  - `Scheduler.swift` — Serial execution context and timers; the test stand-in for Dart's `fake_async`
  - `AppLifecycle.swift` — `LifecycleSource` protocol and the UIKit source (behind `#if canImport(UIKit)`)
- `Tests/MobyBeaconTests/` — Ported from `flutter/test/`, one file per Dart file, same test names
- `Tests/MobyBeaconTests/Support/` — Test doubles: `TestScheduler` (virtual time), `MemoryQueueStorage`, `MockHTTPClient`, `FakeLifecycleSource`, `FixedRandom`

All SDK state lives on one serial scheduler. Tests drive it with `TestScheduler.runUntilIdle()` and `advance(by:)`; no test depends on wall-clock time.

## Releases

Releases are cut from `main` with a clean tree. There is no version constant in the sources; the version lives in the tag, the changelog and the build argument.

1. Add a `## X.Y.Z` section to `CHANGELOG.md` (the zip ships it; the build script refuses a version without one) and commit.
2. `swift test` must pass.
3. Tag and build:
   ```bash
   git tag ios-vX.Y.Z && git push origin main ios-vX.Y.Z
   scripts/build-xcframework.sh X.Y.Z
   ```
   Build with the oldest Xcode version client apps support; the swiftinterfaces are readable by that compiler and newer ones, not older ones. The script writes `build/xcframework/MobyBeacon-X.Y.Z.zip` and `MobyBeacon-X.Y.Z.zip.checksum`, and `BUILD-INFO.txt` inside the package records the Xcode used.
4. Publish, with the checksum in the notes so `binaryTarget(url:checksum:)` users can pin it:
   ```bash
   gh release create ios-vX.Y.Z build/xcframework/MobyBeacon-X.Y.Z.zip \
     --title "iOS SDK X.Y.Z" --notes "SwiftPM checksum: $(cat build/xcframework/MobyBeacon-X.Y.Z.zip.checksum)"
   ```

Apps add the unzipped wrapper package as a local package; the source package in `ios/` is for development.
