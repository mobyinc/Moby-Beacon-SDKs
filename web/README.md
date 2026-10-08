# @moby-beacon/sdk-web — Web SDK

## Install

> **Note:** The package is not published to a registry yet. Until it is, build it from this repo:
>
> ```bash
> cd web
> npm ci
> npm run build   # outputs dist/index.esm.js, dist/index.umd.js and type declarations
> ```

Once published, it will install with:

```bash
npm install @moby-beacon/sdk-web
```

## Quick Start

```typescript
import { MobyBeacon } from '@moby-beacon/sdk-web';

const beacon = new MobyBeacon({
  endpoint: 'https://your-api.example.com',
  apiKey: 'your-api-key',
  userId: 'user-123',
});

// Track an event
beacon.track('page', 'view', { path: '/dashboard' });

// Clean up when done (flushes pending events)
await beacon.destroy();
```

## Configuration

Pass a config object to the `MobyBeacon` constructor:

| Option            | Type       | Required | Default | Description                                    |
| ----------------- | ---------- | -------- | ------- | ---------------------------------------------- |
| `endpoint`        | `string`   | Yes      | —       | API base URL (e.g., `https://api.example.com`) |
| `apiKey`          | `string`   | Yes      | —       | API key sent as the `X-API-Key` header         |
| `userId`          | `string`   | Yes      | —       | Default user ID attached to all events         |
| `flushIntervalMs` | `number`   | No       | `5000`  | Auto-flush interval in milliseconds            |
| `batchSize`       | `number`   | No       | `10`    | Flush when the queue reaches this many events  |
| `maxRetries`      | `number`   | No       | `3`     | Max retry attempts on network/server failure   |
| `onError`         | `function` | No       | —       | Callback for errors (see Error Handling)       |

## Tracking Events

```typescript
beacon.track(category, action, details?, overrides?);
```

| Parameter   | Type     | Description                                                                                                                                     |
| ----------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `category`  | `string` | Event category (e.g., `'page'`, `'button'`). Max 255 chars.                                                                                     |
| `action`    | `string` | Event action (e.g., `'view'`, `'click'`). Max 255 chars.                                                                                        |
| `details`   | `object` | Optional flat key-value pairs. Max 50 keys. String values max 1000 chars. Values must be primitives (`string`, `number`, `boolean`, or `null`). |
| `overrides` | `object` | Optional `{ userId?, timestamp? }` to override defaults for this event.                                                                         |

```typescript
// Basic event
beacon.track('page', 'view');

// With details
beacon.track('button', 'click', { id: 'signup-btn', label: 'Sign Up' });

// Override userId for this event
beacon.track('form', 'submit', { formId: 'contact' }, { userId: 'other-user' });
```

## Batching & Flushing

Events are queued in memory and sent in batches to reduce network requests.

**Automatic flushing** happens when:

- The queue reaches `batchSize` events (default: 10)
- The `flushIntervalMs` timer fires (default: every 5 seconds)
- The page is about to unload (`beforeunload` event)
- The page becomes hidden (`visibilitychange` to `'hidden'`)

Page-unload flushes use `fetch` with the `keepalive` flag to ensure delivery even as the page closes.

**Manual flushing:**

```typescript
await beacon.flush();
```

## Error Handling

Provide an `onError` callback to handle failures:

```typescript
const beacon = new MobyBeacon({
  endpoint: 'https://api.example.com',
  apiKey: 'your-api-key',
  userId: 'user-123',
  onError: (error) => {
    console.error(`[${error.type}] ${error.message}`);
  },
});
```

The error object:

| Field     | Type                                              | Description                                                                |
| --------- | ------------------------------------------------- | -------------------------------------------------------------------------- |
| `type`    | `'network' \| 'server' \| 'auth' \| 'validation'` | Error category                                                             |
| `message` | `string`                                          | Human-readable error message                                               |
| `events`  | `EventPayload[]`                                  | The events that failed                                                     |
| `errors`  | `EventBatchError[]`                               | Optional. Per-event errors from the server (present for `validation` type) |

**Retry behavior:** Network errors and server errors (5xx, 429) are retried automatically with exponential backoff and jitter, up to `maxRetries` attempts. The SDK respects `Retry-After` headers from the server. Auth errors (401) and validation errors (422) are not retried.

## Lifecycle

Call `destroy()` when you're done with the SDK instance:

```typescript
await beacon.destroy();
```

This flushes any pending events, removes `beforeunload` and `visibilitychange` listeners, and stops the flush timer. After `destroy()`, calls to `track()` are silently ignored.

## UMD / Script Tag Usage

For use without a bundler, load the UMD build via a `<script>` tag:

```html
<script src="path/to/moby-beacon/dist/index.umd.js"></script>
<script>
  const beacon = new MobyBeacon({
    endpoint: 'https://api.example.com',
    apiKey: 'your-api-key',
    userId: 'user-123',
  });

  beacon.track('page', 'view');
</script>
```

The UMD build exposes `MobyBeacon` as a global on `window`.

## Development

```bash
npm ci
npm run build    # rollup → dist/
npm test         # jest
npm run lint
npm run format:check
```

### Releasing

1. Bump `version` in `package.json`.
2. Commit, then tag: `git tag web-vX.Y.Z && git push origin web-vX.Y.Z`.
