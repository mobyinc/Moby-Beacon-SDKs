import { EventPayload, EventBatchError } from './types';
import { Queue } from './queue';
import { Transport, TransportError } from './transport';
import { RetryScheduler } from './retry-scheduler';
import { validateEvent } from './validate';

export type Details = Record<string, string | number | boolean | null>;

export interface MobyBeaconError {
  type: 'network' | 'server' | 'auth' | 'validation';
  events: EventPayload[];
  errors?: EventBatchError[];
  message: string;
}

export interface MobyBeaconConfig {
  endpoint: string;
  apiKey: string;
  userId: string;
  flushIntervalMs?: number;
  batchSize?: number;
  maxRetries?: number;
  onError?: (error: MobyBeaconError) => void;
}

export class MobyBeacon {
  private readonly queue: Queue;
  private readonly transport: Transport;
  private readonly retryScheduler: RetryScheduler;
  private readonly userId: string;
  private readonly batchSize: number;
  private readonly flushIntervalMs: number;
  private readonly onError?: (error: MobyBeaconError) => void;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private isFlushing = false;
  private flushRequested = false;
  private destroyed = false;
  private readonly handleVisibilityChange: () => void;
  private readonly handleBeforeUnload: () => void;

  constructor(config: MobyBeaconConfig) {
    this.userId = config.userId;
    this.batchSize = config.batchSize ?? 10;
    this.flushIntervalMs = config.flushIntervalMs ?? 5000;
    this.onError = config.onError;

    this.queue = new Queue(1000);
    this.transport = new Transport({
      endpoint: config.endpoint,
      apiKey: config.apiKey,
    });
    this.retryScheduler = new RetryScheduler({
      maxRetries: config.maxRetries ?? 3,
      baseDelayMs: 1000,
      maxDelayMs: 30000,
    });

    this.handleVisibilityChange = () => {
      if (document.visibilityState === 'hidden') {
        this.flushUrgent();
      }
    };
    this.handleBeforeUnload = () => {
      this.flushUrgent();
    };

    this.scheduleTimer();
    document.addEventListener('visibilitychange', this.handleVisibilityChange);
    window.addEventListener('beforeunload', this.handleBeforeUnload);
  }

  track(
    category: string,
    action: string,
    details?: Details,
    overrides?: { userId?: string; timestamp?: string },
  ): void {
    if (this.destroyed) return;

    const event: EventPayload = {
      userId: overrides?.userId ?? this.userId,
      category,
      action,
      timestamp: overrides?.timestamp ?? new Date().toISOString(),
      ...(details !== undefined && { details }),
    };

    try {
      validateEvent(event);
      this.queue.enqueue(event);
    } catch (error) {
      this.onError?.({
        type: 'validation',
        events: [event],
        message: error instanceof Error ? error.message : String(error),
      });
      return;
    }

    if (this.queue.size() >= this.batchSize) {
      void Promise.resolve().then(() => this.flush());
    }
  }

  async flush(): Promise<void> {
    if (this.destroyed) return;

    if (this.isFlushing) {
      this.flushRequested = true;
      return;
    }

    const events = this.queue.drain();
    if (events.length === 0) return;

    this.isFlushing = true;
    try {
      await this.sendWithRetry(events);
    } finally {
      this.isFlushing = false;
      if (this.flushRequested) {
        this.flushRequested = false;
        void this.flush();
      }
    }
  }

  async destroy(): Promise<void> {
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    document.removeEventListener('visibilitychange', this.handleVisibilityChange);
    window.removeEventListener('beforeunload', this.handleBeforeUnload);
    try {
      await this.flush();
    } finally {
      this.destroyed = true;
    }
  }

  private scheduleTimer(): void {
    this.timer = setTimeout(async () => {
      await this.flush();
      if (!this.destroyed) {
        this.scheduleTimer();
      }
    }, this.flushIntervalMs);
  }

  private flushUrgent(): void {
    const events = this.queue.drain();
    if (events.length === 0) return;
    this.transport.sendUrgent(events);
  }

  private async sendWithRetry(events: EventPayload[]): Promise<void> {
    for (let attempt = 0; ; attempt++) {
      try {
        const result = await this.transport.send(events);
        if (result.errors.length > 0) {
          this.onError?.({
            type: 'validation',
            events,
            errors: result.errors,
            message: `${result.errors.length} event(s) rejected by server`,
          });
        }
        return;
      } catch (error) {
        const transportError = error instanceof TransportError ? error : null;

        const isRetryable =
          transportError === null ||
          transportError.statusCode === undefined ||
          transportError.statusCode === 429 ||
          transportError.statusCode >= 500;

        if (isRetryable && this.retryScheduler.shouldRetry(attempt + 1)) {
          const delay = this.retryScheduler.getDelay(attempt, transportError?.retryAfter);
          await new Promise((resolve) => setTimeout(resolve, delay));
          continue;
        }

        let errorType: MobyBeaconError['type'];
        if (transportError === null || transportError.statusCode === undefined) {
          errorType = 'network';
        } else if (transportError.statusCode >= 500 || transportError.statusCode === 429) {
          errorType = 'server';
        } else {
          errorType = 'auth';
        }

        this.onError?.({
          type: errorType,
          events,
          message: error instanceof Error ? error.message : String(error),
        });
        return;
      }
    }
  }
}
