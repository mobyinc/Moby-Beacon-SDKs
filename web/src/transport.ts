import { EventPayload, EventBatchResponse } from './types';

export interface TransportConfig {
  endpoint: string;
  apiKey: string;
}

export class TransportError extends Error {
  readonly statusCode?: number;
  readonly retryAfter?: number;

  constructor(message: string, statusCode?: number, retryAfter?: number) {
    super(message);
    this.name = 'TransportError';
    this.statusCode = statusCode;
    this.retryAfter = retryAfter;
  }
}

export class Transport {
  private readonly endpoint: string;
  private readonly apiKey: string;

  constructor(config: TransportConfig) {
    this.endpoint = config.endpoint;
    this.apiKey = config.apiKey;
  }

  async send(events: EventPayload[]): Promise<EventBatchResponse> {
    let response: Response;
    try {
      response = await fetch(`${this.endpoint}/events`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-API-Key': this.apiKey,
        },
        body: JSON.stringify({ events }),
      });
    } catch (error) {
      throw new TransportError(error instanceof Error ? error.message : 'Network error');
    }

    if (response.status === 429) {
      const retryAfter = response.headers.get('Retry-After');
      throw new TransportError(
        'Rate limited',
        429,
        retryAfter ? parseInt(retryAfter, 10) : undefined,
      );
    }

    if (response.status >= 500) {
      throw new TransportError(`Server error: ${response.status}`, response.status);
    }

    if (response.status === 201 || response.status === 207 || response.status === 422) {
      return (await response.json()) as EventBatchResponse;
    }

    throw new TransportError(`Client error: ${response.status}`, response.status);
  }

  sendUrgent(events: EventPayload[]): void {
    fetch(`${this.endpoint}/events`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': this.apiKey,
      },
      body: JSON.stringify({ events }),
      keepalive: true,
    }).catch(() => {
      // Fire-and-forget — swallow errors during page unload
    });
  }
}
