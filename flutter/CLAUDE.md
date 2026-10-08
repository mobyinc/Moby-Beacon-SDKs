# moby_beacon (Flutter SDK)

Flutter/Dart SDK for sending events from iOS and Android study apps to the Moby Beacon API. Counterpart of `@moby-beacon/sdk-web`; keep behavior aligned where the platforms allow.

## Commands

- `flutter pub get` — Install dependencies (also run in `example/`)
- `flutter test` — Run tests
- `flutter analyze` — Lint (strict casts/inference/raw types)

## Layout

- `lib/moby_beacon.dart` — Public exports only
- `lib/src/` — Implementation:
  - `moby_beacon.dart` — `MobyBeacon`: track/flush/dispose, timer, lifecycle; wires the pieces below
  - `config.dart` — `MobyBeaconConfig` and its argument checks
  - `validate.dart` — `validateEvent()`, mirrors the API's ingest rules
  - `backoff.dart` — `nextFlushDelay()`
  - `event_store.dart` — `EventStore`: FIFO queue with coalesced writes
  - `queue_storage.dart` — `QueueStorage` interface and `FileQueueStorage` (`queue.json`)
  - `transport.dart` — `Transport`: HTTP send and status/`Retry-After` mapping
  - `event.dart`, `errors.dart` — Event and error types
- `test/support/` — Test doubles:
  - `MemoryQueueStorage` — in-memory `QueueStorage` with `readError`, `writeError`, and `writeGate` hooks to simulate unreadable storage, failed writes, and writes held in flight
  - `FixedRandom` — deterministic jitter
- `example/` — Dart sources only; platform folders are generated locally (see `README.md`)

Use the `test/support/` doubles with `fake_async`; real file I/O doesn't advance under fake time, so only `FileQueueStorage` tests touch the disk.

## Releases

Tag `flutter-vX.Y.Z`; apps pin the tag as a git dependency `ref` (`path: flutter`).
