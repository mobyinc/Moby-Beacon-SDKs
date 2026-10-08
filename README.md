# Moby Beacon SDKs

Client SDKs for Moby Beacon, an append-only event logging API for study-scoped behavioral research.

| SDK                     | Path                   | Platforms                    |
| ----------------------- | ---------------------- | ---------------------------- |
| `moby_beacon` (Flutter) | [`flutter/`](flutter/) | iOS, Android                 |
| `@moby-beacon/sdk-web`  | [`web/`](web/)         | Browsers (ESM bundle or UMD) |

Each SDK batches events, retries transient failures, and sends them to a Moby Beacon API's `POST /events` endpoint with an ingest API key. See each SDK's README for installation, configuration, and behavior.

## Releases

SDKs are versioned independently and tagged per SDK:

- Flutter: `flutter-vX.Y.Z`. Apps pin the tag as the `ref` of a git dependency (`path: flutter`).
- Web: `web-vX.Y.Z`.

## License

[MIT](LICENSE)
