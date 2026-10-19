# MobyBeacon — iOS SDK

`MobyBeacon` sends events from an iOS app to a Moby Beacon API. It mirrors the [Flutter SDK](../flutter/README.md) and is usable from both Swift and Objective-C, with a disk-backed queue so events survive app restarts and offline periods.

## Install

Each release ships the SDK as a prebuilt `MobyBeacon.xcframework` wrapped in a small Swift package, attached to the `ios-v<version>` release on this repo's Releases page. An app adds it like any other package and never compiles the SDK's sources. The same binary works from Swift and Objective-C. Requires iOS 15+. For a prebuilt release, use the Xcode version recorded in `BUILD-INFO.txt` or a newer compatible toolchain; a binary built with a newer Swift compiler is not guaranteed to import into an older Xcode. Building the SDK from source requires Xcode 15+.

1. Download `MobyBeacon-<version>.zip` from the release and unzip it. The folder contains `Package.swift`, `MobyBeacon.xcframework`, `BUILD-INFO.txt`, this README, the changelog and the license.
2. Put the folder in your project's repository, for example `Vendor/MobyBeacon-0.1.0/`.
3. In Xcode choose File ▸ Add Package Dependencies… ▸ Add Local…, pick that folder, and add the `MobyBeacon` product to the app target. Xcode links the right slice for devices and the simulator and embeds the framework automatically.

Then import the module:

```swift
import MobyBeacon
```

```objc
@import MobyBeacon;
```

To upgrade, replace the folder with the new release's folder. Xcode picks up the new binary on the next build.

A Swift package that depends on the SDK references the same folder with `.package(path: "Vendor/MobyBeacon-0.1.0")` and the product with `.product(name: "MobyBeacon", package: "MobyBeacon-0.1.0")` (a local package's identity is its folder name).

### Fetching from GitHub instead of vendoring

SwiftPM can download the release zip itself through a binary target that names the release asset's URL and the checksum from the release notes. SwiftPM finds the XCFramework inside the wrapper folder in the zip. An app target cannot declare a binary target directly, so the declaration goes in a Swift package the app depends on, for example a small local package inside the app's repository:

```swift
// Packages/MobyBeaconBinary/Package.swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MobyBeaconBinary",
    platforms: [.iOS(.v15)],
    products: [.library(name: "MobyBeacon", targets: ["MobyBeacon"])],
    targets: [
        .binaryTarget(
            name: "MobyBeacon",
            url: "https://github.com/mobyinc/Moby-Beacon-SDKs/releases/download/ios-v0.1.0/MobyBeacon-0.1.0.zip",
            checksum: "<SwiftPM checksum from the release notes>"),
    ]
)
```

Add that package with Add Local… and link its `MobyBeacon` product. To upgrade, change the URL and checksum. Builds need network access to GitHub until the zip is in SwiftPM's cache; the vendored folder above is the offline alternative.

## Platform Setup

- **HTTPS endpoints** need nothing.
- **Plain-HTTP endpoints** (local development or staging) are accepted by `MobyBeaconConfig`, but iOS App Transport Security blocks them. Every send fails as a `network` error and events stay queued. Add an `NSAppTransportSecurity` exception to the app's `Info.plist`: `NSAllowsLocalNetworking` set to `YES` for a local server (`localhost`, `.local` hosts, or IP addresses), or an `NSExceptionDomains` entry for the specific host. Remove the exception for release builds that use HTTPS.

## Quick Start

Swift:

```swift
import MobyBeacon

do {
    let config = try MobyBeaconConfig(
        endpoint: "https://your-api.example.com",
        apiKey: "your-ingest-key",
        userId: "participant-042")
    let beacon = try MobyBeacon.start(config: config)
    beacon.track("app", "open")
} catch {
    print("MobyBeacon setup failed: \(error.localizedDescription)")
}
```

Objective-C:

```objc
@import MobyBeacon;

NSError *error = nil;
MobyBeaconConfig *config = [[MobyBeaconConfig alloc] initWithEndpoint:@"https://your-api.example.com"
                                                               apiKey:@"your-ingest-key"
                                                               userId:@"participant-042"
                                                                error:&error];
MobyBeacon *beacon = config ? [MobyBeacon startWithConfig:config error:&error] : nil;
if (beacon) {
    [beacon track:@"app" action:@"open" details:nil];
} else {
    NSLog(@"MobyBeacon setup failed: %@", error.localizedDescription);
}
```

Start **one** instance per app and keep a reference to it, for example in your app delegate or a singleton. Every instance uses the same queue file, so two live instances would conflict: `start(config:)` throws `MobyBeaconSetupError.alreadyRunning` while another instance exists and its `dispose` has not completed.

`start(config:)` can be called from any thread. It also throws if the Application Support directory cannot be located, or if `flushInterval`, `batchSize`, or `maxQueueSize` is not positive.

## Configuration

| Option          | Type                              | Required | Default  | Description                                                                          |
| --------------- | --------------------------------- | -------- | -------- | ------------------------------------------------------------------------------------ |
| `endpoint`      | `String`                          | Yes      | —        | API base URL (e.g., `https://api.example.com`). Trailing `/` characters are removed; a query string, fragment or whitespace is rejected. |
| `apiKey`        | `String`                          | Yes      | —        | Ingest API key, sent as the `X-API-Key` header. Must not be blank or contain control characters such as a trailing newline. |
| `userId`        | `String`                          | Yes      | —        | Default user ID attached to all events                                               |
| `flushInterval` | `TimeInterval` (seconds)          | No       | `5`      | Time between automatic flushes while sends succeed                                   |
| `batchSize`     | `Int`                             | No       | `10`     | Flush as soon as this many events are queued (while sends are healthy)               |
| `maxQueueSize`  | `Int`                             | No       | `10000`  | Maximum events held on disk. New events are rejected when full.                      |
| `onError`       | `((MobyBeaconError) -> Void)?`    | No       | —        | Error callback (see Error Handling)                                                  |

`endpoint`, `apiKey`, and `userId` are initializer arguments. `flushInterval`, `batchSize`, `maxQueueSize`, and `onError` are properties you set on the config before starting:

```swift
let config = try MobyBeaconConfig(endpoint: "...", apiKey: "...", userId: "...")
config.flushInterval = 10
config.batchSize = 25
config.onError = { error in /* ... */ }
```

```objc
config.flushInterval = 10;
config.batchSize = 25;
config.onError = ^(MobyBeaconError *error) { /* ... */ };
```

`MobyBeaconConfig(endpoint:apiKey:userId:)` (Objective-C: `-initWithEndpoint:apiKey:userId:error:`) throws a `MobyBeaconSetupError` when:

- `apiKey` or `userId` is empty or whitespace-only
- `userId` is longer than 255 characters or contains a NUL character
- `endpoint` is not an absolute `http` or `https` URL

`start(config:)` throws a `MobyBeaconSetupError` when `flushInterval` is zero or negative, or `batchSize` or `maxQueueSize` is below 1. Into Objective-C, these arrive as an `NSError` whose `localizedDescription` explains the problem.

`onError` and every completion block are delivered on the **main queue**.

## Tracking Events

```swift
beacon.track(category, action, details: details, userId: userId, timestamp: timestamp)
```

Objective-C has two forms: `-track:action:details:` and `-track:action:details:userId:timestamp:`.

| Parameter   | Type                | Description                                                                                                                                                     |
| ----------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `category`  | `String`            | Event category (e.g., `"screen"`, `"survey"`). Required, max 255 chars.                                                                                         |
| `action`    | `String`            | Event action (e.g., `"view"`, `"answer"`). Required, max 255 chars.                                                                                             |
| `details`   | `[String: Any]?`    | Optional flat key-value pairs (an `NSDictionary` in Objective-C). Max 50 keys, keys max 255 chars. Values must be `String` (max 1000 chars), a finite number (`NSNumber`), `Bool`, or `nil` (`NSNull`). |
| `userId`    | `String?`           | Optional override of the configured `userId` for this event. Max 255 chars, not blank.                                                                          |
| `timestamp` | `Date?`             | Optional override of the event time (defaults to now). Sent as UTC ISO 8601.                                                                                    |

String length limits (255 characters for `category`, `action`, `userId` and `details` keys; 1000 for `details` string values) are counted in UTF-16 code units, so an emoji counts as 2.

No string may contain a NUL (`U+0000`) character. That applies to `category`, `action`, `userId`, `details` keys, and `details` string values.

Unpaired UTF-16 surrogates in those strings are replaced with `U+FFFD` (�) instead of being rejected. These are usually left by cutting text in the middle of an emoji, for example with `NSString`'s `substringToIndex:` on a UTF-16 offset. Truncate on composed character sequences (`rangeOfComposedCharacterSequencesForRange:`) or use Swift's `String.prefix` to avoid them.

`details` values are copied when you call `track`, so changing the dictionary afterwards does not alter the event.

Swift:

```swift
beacon.track("screen", "view")
beacon.track("survey", "answer", details: ["question": 3, "value": "agree"])
beacon.track("sync", "complete", userId: "other-participant")
```

Objective-C:

```objc
[beacon track:@"screen" action:@"view" details:nil];
[beacon track:@"survey" action:@"answer" details:@{@"question": @3, @"value": @"agree"}];
[beacon track:@"sync" action:@"complete" details:nil userId:@"other-participant" timestamp:nil];
```

`track` never throws and can be called from any thread. Invalid events and events rejected because the queue is full are reported to `onError` as `validation` errors and are not queued.

## Batching, Flushing & Persistence

Events are appended to an in-memory queue that is mirrored to `queue.json` in a `moby_beacon/` directory under the app's Application Support directory. The directory is excluded from device and iCloud backups, so a backup restored onto another device does not resend events the original device already delivered. They stay there until the API confirms them, so events survive the app being killed, the device restarting, and offline periods.

**Automatic flushing** happens when:

- The queue reaches `batchSize` events. This trigger applies only while sends are healthy; after a failure, retries wait for the backoff timer.
- The flush timer fires (every `flushInterval`, or the backoff delay after failures)
- The SDK starts and finds events left from a previous run
- The app goes to the background (`didEnterBackground`)
- The app returns to the foreground (`willEnterForeground`), which also resets backoff

Each request carries at most 1000 events (the API limit) and 64 KiB of event data (the API's request body limit is 100 kB). A larger backlog is sent in consecutive requests.

**Persistence:**

- The queue file is versioned. If it can't be parsed as a whole, it is moved aside to `queue.json.corrupt` and the SDK starts empty.
- Individual entries that can't be read or no longer pass validation are skipped and dropped from disk. Both cases are reported to `onError` as a `validation` error.
- If storage is temporarily unreadable at launch (for example, before the first unlock after a restart), the SDK keeps running from memory, retries the read later (before each write, and when the app returns to the foreground), and merges the stored backlog once it succeeds.

**Manual flushing:**

```swift
beacon.flush { /* queue empty, or a send failed */ }
// or
await beacon.flush()
```

```objc
[beacon flushWithCompletion:^{ /* queue empty, or a send failed */ }];
```

You rarely need this: the SDK flushes on batch size, on a timer, and on app lifecycle changes. It is useful before a known exit point, such as finishing a study session. The completion runs (on the main queue) when queued events are sent or a send fails.

If a flush is already running, `flush` waits for it and for the follow-up run that sends events queued in the meantime. After `dispose`, it sends nothing but still calls the completion.

## Error Handling

```swift
config.onError = { error in
    print("[\(error.type)] \(error.message) (willRetry: \(error.willRetry))")
}
```

```objc
config.onError = ^(MobyBeaconError *error) {
    NSLog(@"[%ld] %@ (willRetry: %d)", (long)error.type, error.message, error.willRetry);
};
```

The callback runs on the main queue. The error object:

| Field       | Type                        | Description                                                                          |
| ----------- | --------------------------- | ------------------------------------------------------------------------------------ |
| `type`      | `MobyBeaconErrorType`       | `network`, `server`, `auth`, or `validation` (Objective-C: `MobyBeaconErrorTypeNetwork`, and so on) |
| `message`   | `String`                    | Human-readable error message                                                         |
| `events`    | `[MobyBeaconEvent]`         | The events affected                                                                  |
| `errors`    | `[EventBatchError]?` (Objective-C: `MobyBeaconEventBatchError`) | Per-event errors from the server (207/422); `index` refers to a position in `events` |
| `willRetry` | `Bool`                      | `true` if the events are still queued and will be retried                            |

| Type         | Cause                                                                                                                                           | Events                              |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| `network`    | No response (offline, DNS, TLS, 30s timeout)                                                                                                    | Kept and retried                    |
| `server`     | HTTP 408, 429, or 5xx                                                                                                                           | Kept and retried                    |
| `server`     | A 3xx redirect (message starts with "Unexpected redirect", usually a wrong `endpoint`), 404, 400, or any other unexpected status                | Kept, retried about every 5 minutes |
| `auth`       | HTTP 401 or 403 (wrong, revoked, or rotated API key)                                                                                            | Kept, retried about every 5 minutes |
| `validation` | Invalid event, queue full, server rejected events (207/422), a single event too large for the API (413), or an unreadable queue file or entries | Dropped                             |

**HTTP 413 (request too large):** the SDK halves the batch size and retries immediately. This isn't counted as a failure and nothing is reported. If a single event is still rejected, it is dropped and reported as a `validation` error ("Event is larger than the API accepts"). The smaller limit applies until the queue drains or an oversized event is dropped.

**Retry behavior:** after a network, server, or auth failure the SDK stops flushing and waits before the next attempt.

- The base wait is `flushInterval × 2^failures`, never shorter than `flushInterval` and capped at the larger of 5 minutes and `flushInterval`. 0–25% jitter is then added on top (so up to 6¼ minutes with the defaults).
- On a 429, a plain `Retry-After` (integer seconds) is used if present; otherwise the longest `Retry-After-<name>` header (the API's rate limiter sends these). HTTP-date values are ignored. The value is clamped to the same floor and ceiling, without jitter.
- `auth` errors and unexpected statuses (3xx, 404, 400, and so on) usually need a fix outside the app, such as a new API key or a corrected endpoint or proxy. Events are kept and retried at the ceiling (about every 5 minutes, without jitter) until the fix is in place.
- There's no retry limit, because events are safe on disk. The queue is bounded by `maxQueueSize`: once it is full, new events are rejected and reported as `validation` errors.
- The failure count resets when the server accepts a batch (201, 207, or 422) or answers 413, and when the app returns to the foreground.

The SDK is silent by default: no logging, no thrown errors from `track`. Set `onError` to see failures.

**Setup errors from Objective-C:** a `MobyBeaconSetupError` thrown by `-initWithEndpoint:apiKey:userId:error:` or `+startWithConfig:error:` arrives as an `NSError` with domain `MobyBeaconSetupErrorInfo.domain` (`"MobyBeacon.SetupError"`) and a `MobyBeaconSetupErrorCode` as its `code`. The codes are stable (`MobyBeaconSetupErrorCodeInvalidEndpoint` = 1 through `MobyBeaconSetupErrorCodeStorageUnavailable` = 10). Swift can read the same value from the error's `code` property.

```objc
if ([error.domain isEqualToString:MobyBeaconSetupErrorInfo.domain] && error.code == MobyBeaconSetupErrorCodeAlreadyRunning) {
    // Wait for the previous instance's dispose to complete, then start again.
}
```

## Lifecycle

The SDK observes the app lifecycle itself; no extra wiring is needed.

- **Entering the background:** it saves the queue and tries to send. The flush runs inside a `UIApplication` background task, so iOS gives it time to finish after the app is suspended; the task ends when the flush settles or when the system's time runs out.
- **Returning to the foreground:** it retries reading any unreadable stored backlog, then sends.
- **Termination:** on `willTerminate` it saves the queue. This is best effort, since iOS often kills an app without sending the notification; events are normally already on disk from earlier writes.

If you need to tear it down (e.g., on logout before starting an instance for a different participant):

```swift
beacon.dispose { /* done */ }
// or
await beacon.dispose()
```

```objc
[beacon disposeWithCompletion:^{ /* done */ }];
```

This stops the timer and lifecycle observers, waits for any running flush, and sends what it can. Anything unsent stays on disk and is sent by the next instance. Calling `dispose` again is safe; the completion runs when the first call finishes. After `dispose`, `track` and `flush` do nothing.

Offline, `dispose` can take up to about 60 seconds: a request already in flight may run to its 30-second timeout, and the final flush makes one more attempt.

Only one instance can be live at a time, because instances share the queue file. `start(config:)` throws `MobyBeaconSetupError.alreadyRunning` if another instance exists and its `dispose` hasn't completed, so wait for the completion before starting the next one.

## Known Limitations

- **At-least-once delivery.** If the app is killed after the API accepts a batch but before the SDK removes it from disk, that batch is sent again on the next launch. The same applies to a request that times out client-side but completes on the server late. Analyses that count events should tolerate occasional duplicates.
- **No background sending.** Beyond the short background task when the app enters the background, nothing is sent while the app is suspended. Events queued then are sent the next time it runs.
- **Memory-only window while storage is unreadable.** Events tracked while the queue file can't be read yet are held in memory only. If the app exits before a read succeeds, they are lost.
- **iOS 15+ only.** The package also builds on macOS 12+ so its tests can run there, but the lifecycle observers are iOS only.

## Development

Run the tests on macOS:

```bash
cd ios
swift test
```

The test that starts a real instance creates and uses a `moby_beacon/` directory under the test host's Application Support directory (it queues nothing, so no `queue.json` is written) and removes the directory when it finishes, but only if the test created it. If `moby_beacon/` already exists (for example, from an earlier aborted run), the test is skipped so it never touches an existing queue file.

Check that the package compiles for iOS:

```bash
cd ios
xcrun swift build --triple arm64-apple-ios15.0-simulator --sdk $(xcrun --sdk iphonesimulator --show-sdk-path)
```

To work on the SDK itself, add the `ios/` folder of a checkout with Add Local… instead of the release package and link the `MobyBeacon` product. The module name and API are identical, so switching an app between the two needs no code changes.

Build the distributable XCFramework for a release. First add a `## <version>` section to `CHANGELOG.md` and commit; the changelog ships inside the zip and the script refuses a version it does not list.

```bash
ios/scripts/build-xcframework.sh 0.1.0
```

This archives the package for iOS devices and the simulator with library evolution enabled (`BUILD_LIBRARY_FOR_DISTRIBUTION`), and writes `ios/build/xcframework/MobyBeacon-0.1.0/` (the wrapper package), `MobyBeacon-0.1.0.zip` and the zip's SwiftPM checksum. Build release binaries with the oldest Xcode version your client apps support, and verify importing the generated package in that version; library evolution supports compatible newer toolchains, not arbitrary older compilers. `BUILD-INFO.txt` records the Xcode and Swift versions used. Tag the commit `ios-v0.1.0` on `main`, create a GitHub release on that tag, attach the zip and put the checksum in the release notes. The version is stamped into each framework's `Info.plist` as `CFBundleShortVersionString`, with `com.mobyinc.MobyBeacon` as the bundle identifier. The build needs Xcode; `swift test` must pass first.

The Objective-C selectors the app calls (`startWithConfig:error:`, `track:action:details:`, `track:action:details:userId:timestamp:`, `flushWithCompletion:`, `disposeWithCompletion:`, and `initWithEndpoint:apiKey:userId:error:`) are pinned by `Tests/MobyBeaconTests/ObjectiveCSurfaceTests.swift`. After building an XCFramework, the same selectors can be checked in its `Headers/MobyBeacon-Swift.h`. The `async` variants of `flush` and `dispose` are Swift only.
