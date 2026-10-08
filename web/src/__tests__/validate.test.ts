import { validateEvent } from '../validate';
import { EventPayload } from '../types';

describe('validateEvent', () => {
  const validEvent: EventPayload = {
    userId: 'user-1',
    category: 'page',
    action: 'view',
    timestamp: '2026-03-24T12:00:00Z',
    details: { page: '/home' },
  };

  it('accepts a valid event with all fields', () => {
    expect(() => validateEvent(validEvent)).not.toThrow();
  });

  it('accepts a minimal event (no timestamp, no details)', () => {
    expect(() => validateEvent({ userId: 'u', category: 'c', action: 'a' })).not.toThrow();
  });

  it('rejects empty userId', () => {
    expect(() => validateEvent({ ...validEvent, userId: '' })).toThrow('userId');
  });

  it('rejects non-string userId', () => {
    expect(() => validateEvent({ ...validEvent, userId: 123 as unknown as string })).toThrow(
      'userId',
    );
  });

  it('rejects empty category', () => {
    expect(() => validateEvent({ ...validEvent, category: '' })).toThrow('category');
  });

  it('rejects empty action', () => {
    expect(() => validateEvent({ ...validEvent, action: '' })).toThrow('action');
  });

  it('rejects nested object in details', () => {
    const nested = { obj: { a: 1 } } as unknown as EventPayload['details'];
    expect(() => validateEvent({ ...validEvent, details: nested })).toThrow('details');
  });

  it('rejects array value in details', () => {
    const arr = { list: [1, 2] } as unknown as EventPayload['details'];
    expect(() => validateEvent({ ...validEvent, details: arr })).toThrow('details');
  });

  it('rejects non-string timestamp', () => {
    expect(() => validateEvent({ ...validEvent, timestamp: 123 as unknown as string })).toThrow(
      'timestamp',
    );
  });
});
