# moby-beacon — Android SDK

`moby-beacon` sends events from Android apps to a Moby Beacon API. It is a port of the Flutter `moby_beacon` SDK, with the same disk-backed queue, so events survive app restarts and offline periods. It is a Kotlin library module (`com.mobyinc.beacon`) that can be used from Java or Kotlin. The examples below are Java.

## Install

Each release ships the SDK as a prebuilt AAR inside a small Maven repository folder, attached as `moby-beacon-<version>.zip` to the `android-v<version>` release on this repo's Releases page. The folder also holds a POM that lists the SDK's dependencies and a sources jar, so Gradle resolves it like any other library and the app never compiles the SDK's sources. The same binary works from Kotlin and Java. Requires Android Gradle Plugin 8.x, `compileSdk` 36 and `minSdk` 21.

1. Download `moby-beacon-<version>.zip` from the release and unzip it into your project's repository, for example `vendor/moby-beacon-0.1.0/`. The folder contains `repo/`, this README and the changelog.
2. Add the `repo` folder as a Maven repository and depend on the artifact:

```groovy
// settings.gradle
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven { url uri("$rootDir/vendor/moby-beacon-0.1.0/repo") }
    }
}

// app/build.gradle
dependencies {
    implementation 'com.mobyinc:moby-beacon:0.1.0'
}
```

Projects that declare repositories in the root `build.gradle` (`allprojects { repositories { ... } }`) add the `maven { ... }` line there instead. Gradle picks up the SDK's dependencies (`androidx.lifecycle:lifecycle-process` and the Kotlin standard library) from the POM on the next sync.

To upgrade, replace the folder with the new release's folder and bump the version in both lines.

The app needs the INTERNET permission in `AndroidManifest.xml` (inside `<manifest>`):

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

Without it, every send fails as a `NETWORK` error and events stay queued. Plain-HTTP endpoints (local development) are blocked by default when the app's `targetSdk` is 28 or higher; HTTPS endpoints need nothing more.

## Quick Start

Create the instance in `Application.onCreate`:

```java
import android.app.Application;
import com.mobyinc.beacon.MobyBeacon;
import com.mobyinc.beacon.MobyBeaconConfig;

public class MyApp extends Application {
    public static MobyBeacon beacon;

    @Override
    public void onCreate() {
        super.onCreate();

        MobyBeaconConfig config = new MobyBeaconConfig.Builder(
                "https://your-api.example.com",
                "your-ingest-key",
                "participant-042")
            .build();

        beacon = MobyBeacon.create(this, config);
        beacon.track("app", "open");
    }
}
```

Create **one** instance per app and reuse it. Every instance uses the same queue file, so two live instances would conflict: `MobyBeacon.create()` throws `IllegalStateException` if another instance has not been disposed.

`create()` returns immediately. Loading the stored queue and sending run on a background thread, and events tracked in the meantime are queued normally.

## Configuration

Build a config with `MobyBeaconConfig.Builder(endpoint, apiKey, userId)`, then the optional setters, then `build()`.

| Builder method                    | Type                      | Required | Default | Description                                                                          |
| --------------------------------- | ------------------------- | -------- | ------- | ------------------------------------------------------------------------------------ |
| `Builder(endpoint, ...)`          | `String`                  | Yes      | —       | API base URL (e.g., `https://api.example.com`). Trailing `/` characters are removed. |
| `Builder(..., apiKey, ...)`       | `String`                  | Yes      | —       | Ingest API key, sent as the `X-API-Key` header                                       |
| `Builder(..., userId)`            | `String`                  | Yes      | —       | Default user ID attached to all events                                               |
| `flushIntervalMs(long)`           | `long`                    | No       | `5000`  | Milliseconds between automatic flushes while sends succeed                           |
| `batchSize(int)`                  | `int`                     | No       | `10`    | Flush as soon as this many events are queued (while sends are healthy)               |
| `maxQueueSize(int)`               | `int`                     | No       | `10000` | Maximum events held on disk. New events are rejected when full.                      |
| `onError(MobyBeaconErrorHandler)` | `MobyBeaconErrorHandler`  | No       | none    | Error callback (see Error Handling)                                                  |

```java
MobyBeaconConfig config = new MobyBeaconConfig.Builder(endpoint, apiKey, userId)
    .flushIntervalMs(5000)
    .batchSize(10)
    .maxQueueSize(10000)
    .onError(error -> { /* see Error Handling */ })
    .build();
```

`build()` throws `IllegalArgumentException` when:

- `endpoint` is not an absolute `http` or `https` URL with a host
- `apiKey` is empty or whitespace-only
- `userId` is empty or whitespace-only, longer than 255 characters, or contains a NUL (`U+0000`) character
- `flushIntervalMs` is zero or negative
- `batchSize` or `maxQueueSize` is less than 1

## Tracking Events

```java
beacon.track(category, action);
beacon.track(category, action, details);
beacon.track(category, action, details, userId, timestampMs);
```

| Parameter     | Type                  | Description                                                                                                                                          |
| ------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `category`    | `String`              | Event category (e.g., `"screen"`, `"survey"`). Required, max 255 chars.                                                                              |
| `action`      | `String`              | Event action (e.g., `"view"`, `"answer"`). Required, max 255 chars.                                                                                  |
| `details`     | `Map<String, Object>` | Optional flat key-value pairs, or `null`. Max 50 keys, keys max 255 chars. Values must be `String` (max 1000 chars), finite `Number`, `Boolean`, or `null`. |
| `userId`      | `String`              | Optional override of the configured user ID for this event, or `null`. Max 255 chars, not blank.                                                     |
| `timestampMs` | `Long`                | Optional override of the event time in epoch milliseconds, or `null` for now. Sent as UTC ISO 8601.                                                  |

Lengths are counted in UTF-16 code units (`String.length()`). No string may contain a NUL (`U+0000`) character. That applies to `category`, `action`, `userId`, `details` keys, and `details` string values.

Unpaired UTF-16 surrogates in those strings are replaced with `U+FFFD` (�) instead of being rejected. These are usually left by cutting text in the middle of an emoji (for example `text.substring(0, 100)`), and the database can't store them. Cut on code point boundaries to avoid them.

The `details` map is copied before `track()` returns, so changing it afterwards does not affect the queued event.

```java
beacon.track("screen", "view");

Map<String, Object> details = new HashMap<>();
details.put("question", 3);
details.put("value", "agree");
beacon.track("survey", "answer", details);

beacon.track("sync", "complete", null, "other-participant", null);
```

`track()` never throws for invalid event content; passing `null` for `category` or `action` is a programmer error and throws. Invalid events and events rejected because the queue is full are reported to `onError` as `VALIDATION` errors and are not queued.

To change the default user ID, for example after a login, call:

```java
beacon.setUserId("participant-043");
```

It applies to events tracked afterwards without an explicit `userId`. Events already queued keep their user ID. An invalid ID (blank, over 255 characters, or containing NUL) is reported to `onError` as a `VALIDATION` error and ignored. `setUserId` is not part of the Flutter SDK.

## Batching, Flushing & Persistence

Events are appended to an in-memory queue that is mirrored to `moby_beacon/queue.json` inside `Context.getNoBackupFilesDir()`, so it is excluded from Auto Backup. They stay there until the API confirms them, so events survive the app being killed, the device restarting, and offline periods. Disk writes run shortly after `track()` returns. Requests run on their own thread, so a slow or hanging send does not hold writes up. Writes are combined, so an event is not on disk the instant `track()` returns. If a write fails, the SDK keeps the events in memory and writes again on the next change, when the app goes to the background, and on `dispose()`.

**Automatic flushing** happens when:

- The queue reaches `batchSize` events. This trigger applies only while sends are healthy; after a failure, retries wait for the backoff timer.
- The flush timer fires (every `flushIntervalMs`, or the backoff delay after failures)
- The SDK starts and finds events left from a previous run
- The app goes to the background (`ProcessLifecycleOwner` `ON_STOP`)
- The app returns to the foreground (`ON_START`), which also resets backoff

Each request carries at most 1000 events (the API limit) and 64 KiB of event data (the API's request body limit is 100 kB). A larger backlog is sent in consecutive requests.

**Persistence:**

- The queue file is versioned: `{"v":1,"events":[...]}`. If it can't be read or parsed as a whole, it is moved aside to `queue.json.corrupt` and the SDK starts empty. This is reported to `onError` as a `VALIDATION` error.
- Individual entries that can't be read or no longer pass validation are skipped and dropped from disk. This is also reported as a `VALIDATION` error.

**Manual flushing:**

```java
beacon.flush();
```

You rarely need this: the SDK flushes on batch size, on a timer, and when the app moves between background and foreground. `flush()` returns immediately and sends in the background; it does not wait for the result. Success and failure show up through `onError` and the queue draining.

## Error Handling

```java
import android.util.Log;

MobyBeaconConfig config = new MobyBeaconConfig.Builder(endpoint, apiKey, userId)
    .onError(error -> Log.w("Beacon",
        "[" + error.getType() + "] " + error.getMessage()
            + " (willRetry: " + error.getWillRetry() + ")"))
    .build();
```

The error object (`MobyBeaconError`):

| Field         | Type                    | Description                                                                          |
| ------------- | ----------------------- | ------------------------------------------------------------------------------------ |
| `getType()`   | `MobyBeaconErrorType`   | `NETWORK`, `SERVER`, `AUTH`, or `VALIDATION`                                         |
| `getMessage()`| `String`                | Human-readable error message                                                         |
| `getEvents()` | `List<MobyBeaconEvent>` | The events affected                                                                  |
| `getErrors()` | `List<EventBatchError>` | Per-event errors from the server (207/422), else `null`; `getIndex()` refers to a position in `getEvents()` |
| `getWillRetry()` | `boolean`            | `true` if the events are still queued and will be retried                            |

| Type         | Cause                                                                                                                                    | Events                              |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| `NETWORK`    | No response (offline, DNS, TLS, or a timeout: 30 s to connect per route attempt, 30 s to read)                                                                                             | Kept and retried                    |
| `SERVER`     | HTTP 408, 429, or 5xx                                                                                                                    | Kept and retried                    |
| `SERVER`     | A 3xx redirect (message starts with "Unexpected redirect", usually a wrong `endpoint`), 404, 400, or any other unexpected status         | Kept, retried about every 5 minutes |
| `AUTH`       | HTTP 401 or 403 (wrong, revoked, or rotated API key)                                                                                     | Kept, retried about every 5 minutes |
| `VALIDATION` | Invalid event, invalid `setUserId`, queue full, server rejected events (207/422), a single event too large for the API (413), or an unreadable queue file or entries | Dropped                             |

**HTTP 413 (request too large):** the SDK halves the batch size and retries immediately. This isn't counted as a failure and nothing is reported. If a single event is still rejected, it is dropped and reported as a `VALIDATION` error ("Event is larger than the API accepts"). The smaller limit applies until the queue drains or an oversized event is dropped.

**HTTP 207 / 422:** the whole batch is removed from the queue. Events the server rejected are listed in `getErrors()`; `getEvents()` holds the full batch so the indexes line up.

**Retry behavior:** after a network, server, or auth failure the SDK stops flushing and waits before the next attempt.

- The base wait is `flushIntervalMs × 2^failures`, never shorter than `flushIntervalMs` and capped at the larger of 5 minutes and `flushIntervalMs`. 0–25% jitter is then added on top (so up to 6¼ minutes with the defaults).
- On a 429, a plain `Retry-After` (integer seconds) is used if present; otherwise the longest `Retry-After-<name>` header (the API's rate limiter sends these). HTTP-date values are ignored. The value is clamped to the same floor and ceiling, without jitter.
- `AUTH` errors and unexpected statuses (3xx, 404, 400, and so on) usually need a fix outside the app, such as a new API key or a corrected endpoint or proxy. Events are kept and retried at the ceiling (about every 5 minutes, without jitter) until the fix is in place.
- There's no retry limit, because events are safe on disk. The queue is bounded by `maxQueueSize`: once it is full, new events are rejected and reported as `VALIDATION` errors.
- The failure count resets when the server accepts a batch (201, 207, or 422) or answers 413, and when the app returns to the foreground.

**Threading:** `onError` runs on the SDK's background worker thread. The exception is field-validation failures found in `track()` or `setUserId()`, which are reported on the calling thread. Queue-full and JSON-encode rejections from `track()` are reported on the worker thread. Do not touch views from the handler; post to the main thread first. Exceptions thrown inside `onError` are swallowed.

The SDK never logs. Without an `onError` handler, failures are silent.

## Lifecycle

The SDK observes the app's process lifecycle itself; no extra wiring is needed. When the app goes to the background it saves the queue and tries to send. When it returns to the foreground it resets backoff and sends. To change the default user ID while the instance is live (for example after a login), use `setUserId()` (see Tracking Events) instead of disposing it.

If you need to tear it down (e.g., on logout before creating an instance for a different participant):

```java
beacon.dispose();
```

`flush()` and `dispose()` are fire-and-forget: they return immediately and the work happens on the worker thread. `dispose()` removes the lifecycle observer and stops the timer, then makes a final send attempt and saves the queue. Anything unsent stays on disk and is sent by the next instance. Calling `dispose()` again is safe. After `dispose()`, `track()` and `flush()` do nothing.

Only one instance can be live at a time, because instances share the queue file. `MobyBeacon.create()` may be called right after `dispose()` returns. The new instance loads the queue after the old instance's final send and save have finished, so if the device is offline its startup can wait for that last request to time out: 30 s to connect per route attempt plus 30 s to read, so a minute or more. Events tracked on the new instance in the meantime are queued in memory and written to disk once it has loaded.

## Known Limitations

- **At-least-once delivery.** If the app is killed after the API accepts a batch but before the SDK removes it from disk, that batch is sent again on the next launch. The same applies to a request that times out client-side but completes on the server late. Analyses that count events should tolerate occasional duplicates.
- **No background sending.** Events queued while the app is not running are sent the next time it starts. The SDK uses no `WorkManager` or foreground service.
- **Android only**, minSdk 21.

## Development

The library builds on its own from `android/`. Builds need an Android SDK: set `ANDROID_HOME`, or put `sdk.dir=/path/to/sdk` in `android/local.properties` (git-ignored).

Run the JVM unit tests and build the AAR:

```bash
cd android
./gradlew :moby-beacon:testReleaseUnitTest :moby-beacon:assembleRelease
```

To work on the SDK itself from an app, add `android/moby-beacon/` from a checkout as a source module instead of the release folder: include it in `settings.gradle` (`include ':app', ':moby-beacon'`) and depend on `project(':moby-beacon')`. The host project then needs the Kotlin Gradle plugin on its buildscript classpath, even when the app is Java. The package and API are identical, so switching between the two needs no code changes.

Publish a release:

1. Set the new version in `moby-beacon/build.gradle` (`version = '...'`), in the `MobyBeacon.VERSION` constant, and in `CHANGELOG.md`, and commit.
2. Run `./gradlew :moby-beacon:publish`. It writes the AAR, POM, Gradle module metadata and sources jar to `moby-beacon/build/repo/com/mobyinc/moby-beacon/<version>/` (ignored).
3. Run `scripts/package-release.sh <version>`. It copies that version's folder, this README and the changelog into `build/release/moby-beacon-<version>/`, zips it to `moby-beacon-<version>.zip` and prints the zip's SHA-256.
4. Tag the commit `android-v<version>`, create a GitHub release on that tag, attach the zip and put the SHA-256 in the release notes.

`MobyBeacon.VERSION` reports the version at runtime.

## Differences from the Flutter SDK

- Configuration uses `MobyBeaconConfig.Builder` instead of named constructor arguments, and `flushInterval` is `flushIntervalMs` in milliseconds.
- `MobyBeacon.create(context, config)` is synchronous: it returns immediately and loads the queue in the background.
- `setUserId(userId)` is new. The Flutter SDK has no way to change the default user ID.
- `flush()` and `dispose()` are fire-and-forget. There is no awaitable flush, and no way to wait for the final send.
- `onError` is called on the SDK's worker thread rather than the caller's event loop (caller-side validation failures still arrive on the caller's thread).
- Request timeouts are 30 s to connect per route attempt plus 30 s to read, where Flutter uses a 30 s total timeout.
- There is no "storage unreadable at launch" handling. A queue file that can't be read is treated like a corrupt one: it is moved aside to `queue.json.corrupt` and the SDK starts empty.
