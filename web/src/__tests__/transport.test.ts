import { Transport, TransportError } from '../transport';
import { EventPayload } from '../types';

const events: EventPayload[] = [{ userId: 'u', category: 'c', action: 'a' }];

describe('Transport', () => {
  const config = { endpoint: 'https://api.example.com', apiKey: 'test-key' };
  let transport: Transport;

  beforeEach(() => {
    transport = new Transport(config);
    global.fetch = jest.fn();
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('sends to {endpoint}/events with correct headers and body', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({
      status: 201,
      json: () => Promise.resolve({ accepted: 1, errors: [] }),
    });

    await transport.send(events);

    expect(global.fetch).toHaveBeenCalledWith('https://api.example.com/events', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': 'test-key',
      },
      body: JSON.stringify({ events }),
    });
  });

  it('returns EventBatchResponse on 201', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({
      status: 201,
      json: () => Promise.resolve({ accepted: 1, errors: [] }),
    });

    const result = await transport.send(events);
    expect(result).toEqual({ accepted: 1, errors: [] });
  });

  it('returns EventBatchResponse with errors on 207', async () => {
    const response = {
      accepted: 0,
      errors: [{ index: 0, message: 'bad' }],
    };
    (global.fetch as jest.Mock).mockResolvedValue({
      status: 207,
      json: () => Promise.resolve(response),
    });

    const result = await transport.send(events);
    expect(result).toEqual(response);
  });

  it('returns EventBatchResponse on 422', async () => {
    const response = {
      accepted: 0,
      errors: [{ index: 0, message: 'invalid' }],
    };
    (global.fetch as jest.Mock).mockResolvedValue({
      status: 422,
      json: () => Promise.resolve(response),
    });

    const result = await transport.send(events);
    expect(result).toEqual(response);
  });

  it('throws TransportError with statusCode on 5xx', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({ status: 503 });

    const error = await transport.send(events).catch((e) => e);
    expect(error).toBeInstanceOf(TransportError);
    expect(error.statusCode).toBe(503);
  });

  it('throws TransportError on 429 with retryAfter from header', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({
      status: 429,
      headers: {
        get: (name: string) => (name === 'Retry-After' ? '30' : null),
      },
    });

    const error = await transport.send(events).catch((e) => e);
    expect(error).toBeInstanceOf(TransportError);
    expect(error.statusCode).toBe(429);
    expect(error.retryAfter).toBe(30);
  });

  it('throws TransportError on 401', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({ status: 401 });

    const error = await transport.send(events).catch((e) => e);
    expect(error).toBeInstanceOf(TransportError);
    expect(error.statusCode).toBe(401);
  });

  it('throws TransportError on 403', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({ status: 403 });

    const error = await transport.send(events).catch((e) => e);
    expect(error).toBeInstanceOf(TransportError);
    expect(error.statusCode).toBe(403);
  });

  it('wraps network errors in TransportError (no statusCode)', async () => {
    (global.fetch as jest.Mock).mockRejectedValue(new TypeError('Failed to fetch'));

    const error = await transport.send(events).catch((e) => e);
    expect(error).toBeInstanceOf(TransportError);
    expect(error.statusCode).toBeUndefined();
    expect(error.message).toBe('Failed to fetch');
  });

  it('sendUrgent sends with keepalive: true', () => {
    (global.fetch as jest.Mock).mockResolvedValue({});

    transport.sendUrgent(events);

    expect(global.fetch).toHaveBeenCalledWith('https://api.example.com/events', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': 'test-key',
      },
      body: JSON.stringify({ events }),
      keepalive: true,
    });
  });
});
