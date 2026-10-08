export interface RetrySchedulerConfig {
  maxRetries: number;
  baseDelayMs: number;
  maxDelayMs: number;
}

export class RetryScheduler {
  private readonly maxRetries: number;
  private readonly baseDelayMs: number;
  private readonly maxDelayMs: number;

  constructor(config: RetrySchedulerConfig) {
    this.maxRetries = config.maxRetries;
    this.baseDelayMs = config.baseDelayMs;
    this.maxDelayMs = config.maxDelayMs;
  }

  shouldRetry(attempt: number): boolean {
    return attempt <= this.maxRetries;
  }

  getDelay(attempt: number, retryAfter?: number): number {
    if (retryAfter !== undefined) {
      return retryAfter * 1000;
    }
    const exponential = this.baseDelayMs * Math.pow(2, attempt);
    const capped = Math.min(exponential, this.maxDelayMs);
    const jitter = capped * Math.random() * 0.25;
    return capped + jitter;
  }
}
