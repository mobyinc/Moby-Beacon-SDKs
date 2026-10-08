import { MobyBeacon } from '../moby-beacon';

const mockFetch = jest.fn();
global.fetch = mockFetch;

function successResponse() {
  return {
    status: 201,
    json: () => Promise.resolve({ accepted: 1, errors: [] }),
  };
}

function partialResponse() {
  return {
    status: 207,
    json: () =>
      Promise.resolve({
        accepted: 0,
        errors: [{ index: 0, message: 'bad userId' }],
      }),
  };
}

function serverErrorResponse() {
  return { status: 500 };
}

function defaultConfig(overrides = {}) {
  return {
    endpoint: 'https://api.example.com',
    apiKey: 'test-key',
    userId: 'user-1',
    flushIntervalMs: 60000, // long interval to avoid auto-flush in most tests
    batchSize: 10,
    ...overrides,
  };
}

describe('MobyBeacon', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    mockFetch.mockReset();
    mockFetch.mockResolvedValue(successResponse());
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('track()', () => {
    it('queues a validated event with auto-generated timestamp', async () => {
      const beacon = new MobyBeacon(defaultConfig());
      jest.setSystemTime(new Date('2026-03-24T12:00:00Z'));

      beacon.track('page', 'view');
      await beacon.flush();

      const body = JSON.parse(mockFetch.mock.calls[0][1].body);
      expect(body.events).toHaveLength(1);
      expect(body.events[0]).toMatchObject({
        userId: 'user-1',
        category: 'page',
        action: 'view',
        timestamp: '2026-03-24T12:00:00.000Z',
      });

      await beacon.destroy();
    });

    it('respects per-event userId and timestamp overrides', async () => {
      const beacon = new MobyBeacon(defaultConfig());

      beacon.track('page', 'view', undefined, {
        userId: 'other-user',
        timestamp: '2026-01-01T00:00:00Z',
      });
      await beacon.flush();

      const body = JSON.parse(mockFetch.mock.calls[0][1].body);
      expect(body.events[0].userId).toBe('other-user');
      expect(body.events[0].timestamp).toBe('2026-01-01T00:00:00Z');

      await beacon.destroy();
    });

    it('passes details to the event', async () => {
      const beacon = new MobyBeacon(defaultConfig());

      beacon.track('button', 'click', { id: 'signup' });
      await beacon.flush();

      const body = JSON.parse(mockFetch.mock.calls[0][1].body);
      expect(body.events[0].details).toEqual({ id: 'signup' });

      await beacon.destroy();
    });

    it('calls onError on validation failure (does not throw)', async () => {
      const onError = jest.fn();
      const beacon = new MobyBeacon(defaultConfig({ onError }));

      // Empty category triggers validation error
      beacon.track('', 'view');

      expect(onError).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'validation',
          message: expect.stringContaining('category'),
        }),
      );

      await beacon.destroy();
    });

    it('calls onError when queue is full (does not throw)', async () => {
      const onError = jest.fn();
      const beacon = new MobyBeacon(defaultConfig({ onError, batchSize: 1500 }));

      // Fill queue to capacity (1000)
      for (let i = 0; i < 1000; i++) {
        beacon.track('c', `a${i}`);
      }

      // Next enqueue should trigger onError
      beacon.track('c', 'overflow');
      expect(onError).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'validation',
          message: expect.stringContaining('capacity'),
        }),
      );

      await beacon.destroy();
    });
  });

  describe('auto-flush', () => {
    it('flushes when batchSize is reached', async () => {
      const beacon = new MobyBeacon(defaultConfig({ batchSize: 2 }));

      beacon.track('c', 'a');
      beacon.track('c', 'b'); // hits batchSize

      // Flush is scheduled as microtask
      await jest.advanceTimersByTimeAsync(0);

      expect(mockFetch).toHaveBeenCalledTimes(1);
      const body = JSON.parse(mockFetch.mock.calls[0][1].body);
      expect(body.events).toHaveLength(2);

      await beacon.destroy();
    });

    it('flushes on flushIntervalMs timer', async () => {
      const beacon = new MobyBeacon(defaultConfig({ flushIntervalMs: 5000 }));

      beacon.track('c', 'a');

      await jest.advanceTimersByTimeAsync(5000);

      expect(mockFetch).toHaveBeenCalledTimes(1);

      await beacon.destroy();
    });
  });

  describe('flush()', () => {
    it('sends queued events and clears queue', async () => {
      const beacon = new MobyBeacon(defaultConfig());

      beacon.track('c', 'a');
      beacon.track('c', 'b');
      await beacon.flush();

      expect(mockFetch).toHaveBeenCalledTimes(1);
      const body = JSON.parse(mockFetch.mock.calls[0][1].body);
      expect(body.events).toHaveLength(2);

      // Second flush should be no-op (queue empty)
      await beacon.flush();
      expect(mockFetch).toHaveBeenCalledTimes(1);

      await beacon.destroy();
    });

    it('is a no-op when queue is empty', async () => {
      const beacon = new MobyBeacon(defaultConfig());

      await beacon.flush();

      expect(mockFetch).not.toHaveBeenCalled();

      await beacon.destroy();
    });

    it('defers concurrent flush and re-flushes after', async () => {
      let resolveFirst: () => void;

      mockFetch
        .mockImplementationOnce(
          () =>
            new Promise((resolve) => {
              resolveFirst = () =>
                resolve({
                  status: 201,
                  json: () => Promise.resolve({ accepted: 1, errors: [] }),
                });
            }),
        )
        .mockResolvedValueOnce(successResponse());

      const beacon = new MobyBeacon(defaultConfig());

      beacon.track('c', 'first');
      const flush1 = beacon.flush(); // starts flushing

      beacon.track('c', 'second');
      beacon.flush(); // deferred — sets flushRequested

      // Resolve the first flush
      resolveFirst!();
      await flush1;

      // The deferred flush should trigger automatically
      await jest.advanceTimersByTimeAsync(0);

      expect(mockFetch).toHaveBeenCalledTimes(2);

      await beacon.destroy();
    });
  });

  describe('page unload', () => {
    it('flushes with sendUrgent on visibilitychange to hidden', async () => {
      const beacon = new MobyBeacon(defaultConfig());

      beacon.track('c', 'a');

      // Simulate visibilitychange to hidden
      Object.defineProperty(document, 'visibilityState', {
        value: 'hidden',
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event('visibilitychange'));

      // sendUrgent uses fetch with keepalive
      expect(mockFetch).toHaveBeenCalledWith(
        'https://api.example.com/events',
        expect.objectContaining({ keepalive: true }),
      );

      // Restore
      Object.defineProperty(document, 'visibilityState', {
        value: 'visible',
        writable: true,
        configurable: true,
      });

      await beacon.destroy();
    });

    it('flushes with sendUrgent on beforeunload', async () => {
      const beacon = new MobyBeacon(defaultConfig());

      beacon.track('c', 'a');

      window.dispatchEvent(new Event('beforeunload'));

      expect(mockFetch).toHaveBeenCalledWith(
        'https://api.example.com/events',
        expect.objectContaining({ keepalive: true }),
      );

      await beacon.destroy();
    });
  });

  describe('destroy()', () => {
    it('flushes remaining events and cleans up', async () => {
      const beacon = new MobyBeacon(defaultConfig());

      beacon.track('c', 'a');
      await beacon.destroy();

      expect(mockFetch).toHaveBeenCalledTimes(1);
    });

    it('makes subsequent track() and flush() no-ops', async () => {
      const beacon = new MobyBeacon(defaultConfig());
      await beacon.destroy();

      beacon.track('c', 'a');
      await beacon.flush();

      expect(mockFetch).not.toHaveBeenCalled();
    });
  });

  describe('error handling', () => {
    it('calls onError with validation info on 207 partial success', async () => {
      mockFetch.mockResolvedValueOnce(partialResponse());
      const onError = jest.fn();
      const beacon = new MobyBeacon(defaultConfig({ onError }));

      beacon.track('c', 'a');
      await beacon.flush();

      expect(onError).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'validation',
          errors: [{ index: 0, message: 'bad userId' }],
        }),
      );

      await beacon.destroy();
    });

    it('retries on server error then calls onError after exhaustion', async () => {
      mockFetch.mockResolvedValue(serverErrorResponse());
      const onError = jest.fn();
      const beacon = new MobyBeacon(defaultConfig({ onError, maxRetries: 2 }));

      beacon.track('c', 'a');
      const flushPromise = beacon.flush();

      // Advance through retry delays (attempt 0: ~1s, attempt 1: ~2s)
      await jest.advanceTimersByTimeAsync(1500);
      await jest.advanceTimersByTimeAsync(3000);
      await flushPromise;

      // 1 initial + 2 retries = 3 calls
      expect(mockFetch).toHaveBeenCalledTimes(3);
      expect(onError).toHaveBeenCalledWith(expect.objectContaining({ type: 'server' }));

      await beacon.destroy();
    });

    it('calls onError with type auth on 401', async () => {
      mockFetch.mockResolvedValue({ status: 401 });
      const onError = jest.fn();
      const beacon = new MobyBeacon(defaultConfig({ onError }));

      beacon.track('c', 'a');
      await beacon.flush();

      // Auth errors are not retried — onError called immediately
      expect(mockFetch).toHaveBeenCalledTimes(1);
      expect(onError).toHaveBeenCalledWith(expect.objectContaining({ type: 'auth' }));

      await beacon.destroy();
    });

    it('retries on network error then calls onError with type network', async () => {
      mockFetch.mockRejectedValue(new TypeError('Failed to fetch'));
      const onError = jest.fn();
      const beacon = new MobyBeacon(defaultConfig({ onError, maxRetries: 1 }));

      beacon.track('c', 'a');
      const flushPromise = beacon.flush();

      // Advance through retry delay (attempt 0: ~1s)
      await jest.advanceTimersByTimeAsync(1500);
      await flushPromise;

      // 1 initial + 1 retry = 2 calls
      expect(mockFetch).toHaveBeenCalledTimes(2);
      expect(onError).toHaveBeenCalledWith(expect.objectContaining({ type: 'network' }));

      await beacon.destroy();
    });
  });
});
