import { RetryScheduler } from '../retry-scheduler';

describe('RetryScheduler', () => {
  const config = { maxRetries: 3, baseDelayMs: 1000, maxDelayMs: 30000 };

  describe('shouldRetry', () => {
    it('returns true for attempts 1 through maxRetries', () => {
      const scheduler = new RetryScheduler(config);
      expect(scheduler.shouldRetry(1)).toBe(true);
      expect(scheduler.shouldRetry(2)).toBe(true);
      expect(scheduler.shouldRetry(3)).toBe(true);
    });

    it('returns false when attempt exceeds maxRetries', () => {
      const scheduler = new RetryScheduler(config);
      expect(scheduler.shouldRetry(4)).toBe(false);
      expect(scheduler.shouldRetry(5)).toBe(false);
    });
  });

  describe('getDelay', () => {
    it('returns exponential backoff', () => {
      const scheduler = new RetryScheduler(config);
      jest.spyOn(Math, 'random').mockReturnValue(0);
      expect(scheduler.getDelay(0)).toBe(1000);
      expect(scheduler.getDelay(1)).toBe(2000);
      expect(scheduler.getDelay(2)).toBe(4000);
      jest.restoreAllMocks();
    });

    it('caps at maxDelayMs', () => {
      const scheduler = new RetryScheduler({
        ...config,
        maxDelayMs: 3000,
      });
      jest.spyOn(Math, 'random').mockReturnValue(0);
      expect(scheduler.getDelay(2)).toBe(3000);
      jest.restoreAllMocks();
    });

    it('adds jitter (0-25%) to calculated delays', () => {
      const scheduler = new RetryScheduler(config);
      jest.spyOn(Math, 'random').mockReturnValue(1);
      expect(scheduler.getDelay(0)).toBe(1250);
      jest.restoreAllMocks();
    });

    it('uses retryAfter when provided (no jitter)', () => {
      const scheduler = new RetryScheduler(config);
      jest.spyOn(Math, 'random').mockReturnValue(1);
      expect(scheduler.getDelay(0, 5)).toBe(5000);
      jest.restoreAllMocks();
    });
  });
});
