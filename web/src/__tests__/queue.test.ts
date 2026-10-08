import { Queue } from '../queue';
import { EventPayload } from '../types';

const event = (action: string): EventPayload => ({
  userId: 'u',
  category: 'c',
  action,
});

describe('Queue', () => {
  it('enqueues events and reports size', () => {
    const queue = new Queue();
    queue.enqueue(event('a'));
    queue.enqueue(event('b'));
    expect(queue.size()).toBe(2);
  });

  it('drain returns all events and clears the queue', () => {
    const queue = new Queue();
    queue.enqueue(event('a'));
    queue.enqueue(event('b'));
    const drained = queue.drain();
    expect(drained).toEqual([event('a'), event('b')]);
    expect(queue.size()).toBe(0);
    expect(queue.isEmpty()).toBe(true);
  });

  it('drain on empty queue returns empty array', () => {
    const queue = new Queue();
    expect(queue.drain()).toEqual([]);
  });

  it('throws when enqueuing at capacity', () => {
    const queue = new Queue(2);
    queue.enqueue(event('a'));
    queue.enqueue(event('b'));
    expect(() => queue.enqueue(event('c'))).toThrow('capacity');
  });

  it('isEmpty returns true for new queue', () => {
    expect(new Queue().isEmpty()).toBe(true);
  });

  it('isEmpty returns false after enqueue', () => {
    const queue = new Queue();
    queue.enqueue(event('a'));
    expect(queue.isEmpty()).toBe(false);
  });
});
