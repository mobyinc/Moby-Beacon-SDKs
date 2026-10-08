# moby_beacon — Flutter SDK

`moby_beacon` sends events from iOS and Android Flutter apps to a Moby Beacon API. It mirrors the [Web SDK](../web/README.md), and adds a disk-backed queue so events survive app restarts and offline periods.

## Install

Add the SDK as a git dependency, pinned to a release tag:

```yaml
dependencies:
  moby_beacon:
    git:
      url: https://github.com/mobyinc/Moby-Beacon-SDKs.git
      path: flutter
      ref: flutter-v0.1.0
```

Requires Dart 3.5+ and Flutter 3.24+.

## Platform Setup

- **Android release builds** need the INTERNET permission. Flutter's template only adds it to the debug and profile manifests, so add this to `android/app/src/main/AndroidManifest.xml` (inside `<manifest>`):

  ```xml
  <uses-permission android:name="android.permission.INTERNET"/>
  ```

  Without it, every send in a release build fails as a `network` error and events stay queued.

- **iOS** needs nothing for HTTPS endpoints.
- **Plain-HTTP endpoints** (local development) need platform opt-ins; see [Example app](#example-app).

## Quick Start

```dart
import 'package:flutter/widgets.dart';
import 'package:moby_beacon/moby_beacon.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final beacon = await MobyBeacon.create(MobyBeaconConfig(
    endpoint: 'https://your-api.example.com',
    apiKey: 'your-ingest-key',
    userId: 'participant-042',
  ));

  beacon.track('app', 'open');
  runApp(const MyApp());
}
```

Create **one** instance per app and reuse it, for example by passing it down or registering it in your service locator. Every instance uses the same queue file, so two live instances would conflict.

```dart
late final MobyBeacon beacon;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  beacon = await MobyBeacon.create(MobyBeaconConfig(/* ... */));
  runApp(const MyApp());
}
```

`MobyBeacon.create()` needs the Flutter binding, so call `WidgetsFlutterBinding.ensureInitialized()` first if it runs before `runApp`. It throws if the platform's application support directory is unavailable.

## Configuration

| Option          | Type                             | Required | Default | Description                                                                          |
| --------------- | -------------------------------- | -------- | ------- | ------------------------------------------------------------------------------------ |
| `endpoint`      | `String`                         | Yes      | —       | API base URL (e.g., `https://api.example.com`). Trailing `/` characters are removed. |
| `apiKey`        | `String`                         | Yes      | —       | Ingest API key, sent as the `X-API-Key` header                                       |
| `userId`        | `String`                         | Yes      | —       | Default user ID attached to all events                                               |
| `flushInterval` | `Duration`                       | No       | `5s`    | Time between automatic flushes while sends succeed                                   |
| `batchSize`     | `int`                            | No       | `10`    | Flush as soon as this many events are queued (while sends are healthy)               |
| `maxQueueSize`  | `int`                            | No       | `10000` | Maximum events held on disk. New events are rejected when full.                      |
| `onError`       | `void Function(MobyBeaconError)` | No       | —       | Error callback (see Error Handling)                                                  |

`MobyBeaconConfig` throws `ArgumentError` when:

- `apiKey` or `userId` is empty or whitespace-only
- `endpoint` is not an absolute `http` or `https` URL
- `flushInterval`, `batchSize`, or `maxQueueSize` is zero or negative

## Tracking Events

```dart
beacon.track(category, action, {details, userId, timestamp});
```

| Parameter   | Type                   | Description                                                                                                                                |
| ----------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `category`  | `String`               | Event category (e.g., `'screen'`, `'survey'`). Required, max 255 chars.                                                                    |
| `action`    | `String`               | Event action (e.g., `'view'`, `'answer'`). Required, max 255 chars.                                                                        |
| `details`   | `Map<String, Object?>` | Optional flat key-value pairs. Max 50 keys, keys max 255 chars. Values must be `String` (max 1000 chars), finite `num`, `bool`, or `null`. |
| `userId`    | `String`               | Optional override of the configured `userId` for this event. Max 255 chars, not blank.                                                     |
| `timestamp` | `DateTime`             | Optional override of the event time (defaults to now). Sent as UTC ISO 8601.                                                               |

No string may contain a NUL (`U+0000`) character. That applies to `category`, `action`, `userId`, `details` keys, and `details` string values.

Unpaired UTF-16 surrogates in those strings are replaced with `U+FFFD` (�) instead of being rejected. These are usually left by cutting text in the middle of an emoji (for example `text.substring(0, 100)`), and the database can't store them. Truncate by characters (`text.characters.take(100).toString()`) to avoid them.

```dart
beacon.track('screen', 'view');
beacon.track('survey', 'answer', details: {'question': 3, 'value': 'agree'});
beacon.track('sync', 'complete', userId: 'other-participant');
```

`track()` never throws. Invalid events and events rejected because the queue is full are reported to `onError` as `validation` errors and are not queued.

## Batching, Flushing & Persistence

Events are appended to an in-memory queue that is mirrored to `moby_beacon/queue.json` in the app's support directory. They stay there until the API confirms them, so events survive the app being killed, the device restarting, and offline periods.

**Automatic flushing** happens when:

- The queue reaches `batchSize` events. This trigger applies only while sends are healthy; after a failure, retries wait for the backoff timer.
- The flush timer fires (every `flushInterval`, or the backoff delay after failures)
- The SDK starts and finds events left from a previous run
- The app goes to the background (`paused` / `hidden`)
- The app returns to the foreground (`resumed`), which also resets backoff

Each request carries at most 1000 events (the API limit) and 64 KiB of event data (the API's request body limit is 100 kB). A larger backlog is sent in consecutive requests.

**Persistence:**

- The queue file is versioned. If it can't be parsed as a whole, it is moved aside to `queue.json.corrupt` and the SDK starts empty.
- Individual entries that can't be read or no longer pass validation are skipped and dropped from disk. Both cases are reported to `onError` as a `validation` error.
- If storage is temporarily unreadable at launch (for example, on iOS before the first unlock after a restart), the SDK keeps running from memory, retries the read later (before each write, and when the app resumes), and merges the stored backlog once it succeeds.

**Manual flushing:**

```dart
await beacon.flush();
```

You rarely need this: the SDK flushes on batch size, on a timer, and on app lifecycle changes. It is useful before a known exit point, such as finishing a study session. `flush()` waits until queued events are sent or a send fails.

If a flush is already running, `flush()` waits for it and for the follow-up run that sends events queued in the meantime. After `dispose()` it does nothing.

## Error Handling

```dart
final beacon = await MobyBeacon.create(MobyBeaconConfig(
  endpoint: 'https://api.example.com',
  apiKey: 'your-ingest-key',
  userId: 'participant-042',
  onError: (error) {
    debugPrint('[${error.type.name}] ${error.message} (willRetry: ${error.willRetry})');
  },
));
```

The error object:

| Field       | Type                     | Description                                                                          |
| ----------- | ------------------------ | ------------------------------------------------------------------------------------ |
| `type`      | `MobyBeaconErrorType`    | `network`, `server`, `auth`, or `validation`                                         |
| `message`   | `String`                 | Human-readable error message                                                         |
| `events`    | `List<MobyBeaconEvent>`  | The events affected                                                                  |
| `errors`    | `List<EventBatchError>?` | Per-event errors from the server (207/422); `index` refers to a position in `events` |
| `willRetry` | `bool`                   | `true` if the events are still queued and will be retried                            |

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

The SDK is silent by default: no logging, no thrown errors. Exceptions thrown inside `onError` are swallowed.

## Lifecycle

The SDK observes the app lifecycle itself; no extra wiring is needed. When the app is paused or hidden it saves the queue and tries to send. When the app resumes it retries reading any unreadable stored backlog, then sends.

If you need to tear it down (e.g., on logout before creating an instance for a different participant):

```dart
await beacon.dispose();
```

This stops the timer and lifecycle observer, waits for any running flush, and sends what it can. Anything unsent stays on disk and is sent by the next instance. Calling `dispose()` again is safe. After `dispose()`, `track()` and `flush()` do nothing.

Offline, `dispose()` can take up to about 60 seconds: a request already in flight may run to its 30-second timeout, and the final flush makes one more attempt.

Only one instance can be live at a time, because instances share the queue file. `MobyBeacon.create()` throws a `StateError` if another instance exists and its `dispose()` hasn't completed, so `await` it before creating the next one.

## Known Limitations

- **At-least-once delivery.** If the app is killed after the API accepts a batch but before the SDK removes it from disk, that batch is sent again on the next launch. The same applies to a request that times out client-side but completes on the server late. Analyses that count events should tolerate occasional duplicates.
- **No background sending.** Events queued while the app is suspended are sent the next time it runs.
- **Memory-only window while storage is unreadable.** Events tracked while the queue file can't be read yet are held in memory only. If the app exits before a read succeeds, they are lost.
- **iOS and Android only.** Flutter web apps should use the [Web SDK](../web/README.md).

## Development

```bash
flutter pub get
flutter test
flutter analyze
```

### Example app

`example/` holds only Dart sources. Platform folders are generated locally and are git-ignored:

```bash
cd example
flutter create . --platforms=ios,android --project-name moby_beacon_example
rm -rf test   # the generated widget test breaks `flutter analyze`
flutter run --dart-define=BEACON_API_KEY=<ingest key>
```

Pass `--dart-define=BEACON_ENDPOINT=<url>` to point at a different API. Without `BEACON_API_KEY` the app shows an instruction screen.

To keep both values in a file, copy `defines.example.json` to `defines.json` (git-ignored), fill it in, and run `flutter run --dart-define-from-file=defines.json`.

The default endpoint is the local API (port 3011) as seen from the device:

| Target           | Default endpoint        |
| ---------------- | ----------------------- |
| Android emulator | `http://10.0.2.2:3011`  |
| iOS simulator    | `http://localhost:3011` |

Plain-HTTP endpoints need a platform opt-in:

- **Android:** the generated `android/app/src/debug/AndroidManifest.xml` has no `<application>` element. Add one inside `<manifest>`; manifest merging applies it to debug builds only:

  ```xml
  <application android:usesCleartextTraffic="true" />
  ```

- **iOS:** in `ios/Runner/Info.plist`, add `NSAppTransportSecurity` with `NSAllowsLocalNetworking` set to `YES`.

### Releasing

1. Bump `version` in `pubspec.yaml` and add a `CHANGELOG.md` entry.
2. Commit, then tag: `git tag flutter-vX.Y.Z && git push origin flutter-vX.Y.Z`.
3. Apps update the `ref:` in their git dependency.
