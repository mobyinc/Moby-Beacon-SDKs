# moby-beacon (Android SDK)

Kotlin library for sending events from Android study apps to the Moby Beacon API, callable from Kotlin and Java. Port of the Flutter `moby_beacon` SDK; keep behavior aligned where the platforms allow. Depends only on the Kotlin stdlib and `androidx.lifecycle:lifecycle-process`; HTTP and JSON use the platform's `HttpURLConnection` and `org.json`.

## Commands

Builds need an Android SDK: set `ANDROID_HOME`, or put `sdk.dir=/path/to/sdk` in `local.properties` here (git-ignored).

- `./gradlew :moby-beacon:assembleRelease` — Build the library; the AAR lands in `moby-beacon/build/outputs/aar/`
- `./gradlew :moby-beacon:testReleaseUnitTest` — Run the JVM unit tests (no device or emulator)
- `./gradlew :moby-beacon:lint` — Android lint
- `./gradlew :moby-beacon:publish` — Publish the release AAR, POM and sources jar to `moby-beacon/build/repo/` (ignored; `-PmobyBeaconRepo=<dir>` redirects it)
- `scripts/package-release.sh <version>` — Zip a published version with the README and changelog into `build/release/` (ignored) for a GitHub release

## Layout

- `moby-beacon/src/main/java/com/mobyinc/beacon/` — Implementation, one file per Flutter module:
  - `MobyBeacon.kt` — `MobyBeacon`: create/track/setUserId/flush/dispose, the flush loop, 413 halving, timer, lifecycle handling, single live instance
  - `MobyBeaconConfig.kt` — `MobyBeaconConfig` and its `Builder`; the argument checks run in `build()`
  - `MobyBeaconError.kt`, `MobyBeaconEvent.kt` — Error and event types, `EventBatchError`, and the `Iso8601` timestamp format
  - `Validate.kt` — `validateEvent()`, `validateUserId()` and `sanitizeEvent()`, mirrors the API's ingest rules
  - `Backoff.kt` — `nextFlushDelayMs()`
  - `EventStore.kt` — `EventStore`: FIFO queue with coalesced writes
  - `QueueStorage.kt` — `QueueStorage` interface and `FileQueueStorage` (`queue.json` under `noBackupFilesDir`)
  - `Transport.kt` — `Transport`: HTTP send and status/`Retry-After` mapping, behind the `EventTransport` seam
  - `Worker.kt` — `Scheduler` interface, the process-wide `Worker` (one worker thread for state, one sender thread for HTTP) and `SerialJobs`
  - `AppLifecycle.kt` — `LifecycleSource` interface and `ProcessLifecycleSource` over `ProcessLifecycleOwner`
- `moby-beacon/src/test/java/com/mobyinc/beacon/` — Ported from `flutter/test/` and `ios/Tests/`, one file per source file, same test names. `BeaconHarness.kt` is the shared per-test setup; `JavaSurfaceTest.java` checks the API from Java.
- `moby-beacon/src/test/java/com/mobyinc/beacon/support/` — Test doubles: `TestScheduler` (virtual time), `MemoryQueueStorage`, `MockHttpClient`, `FakeLifecycleSource`, `FixedRandom`, `Fixtures`

All SDK state lives on the worker thread. Tests drive it with `TestScheduler.runUntilIdle()` and `advanceBy()`; no test depends on wall-clock time.

## Releases

Releases are cut from `main` with a clean tree.

1. Set the same version in three places and commit: `version` in `moby-beacon/build.gradle`, `MobyBeacon.VERSION` in `MobyBeacon.kt`, and a `## X.Y.Z` section in `CHANGELOG.md`. The packaging script refuses a version any of them does not declare.
2. `./gradlew :moby-beacon:testReleaseUnitTest` and `python3 scripts/test_package_release.py` must pass.
3. Tag, publish and package:
   ```bash
   git tag android-vX.Y.Z && git push origin main android-vX.Y.Z
   ./gradlew :moby-beacon:publish
   scripts/package-release.sh X.Y.Z
   ```
   `publish` writes the AAR, POM, Gradle module metadata and sources jar to `moby-beacon/build/repo/`; the script zips that version's folder with the README, changelog and license to `build/release/moby-beacon-X.Y.Z.zip` and writes `moby-beacon-X.Y.Z.zip.sha256`.
4. Publish, with the SHA-256 in the notes:
   ```bash
   gh release create android-vX.Y.Z build/release/moby-beacon-X.Y.Z.zip \
     --title "Android SDK X.Y.Z" --notes "SHA-256: $(cut -d' ' -f1 build/release/moby-beacon-X.Y.Z.zip.sha256)"
   ```

Apps unzip the release folder into their project and point Gradle at `repo/` inside it; the source module in `android/moby-beacon/` is for development.
