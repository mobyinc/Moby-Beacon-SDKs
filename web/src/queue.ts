import { EventPayload } from './types';

export class Queue {
  private buffer: EventPayload[] = [];
  private readonly maxSize: number;

  constructor(maxSize: number = 1000) {
    this.maxSize = maxSize;
  }

  enqueue(event: EventPayload): void {
    if (this.buffer.length >= this.maxSize) {
      throw new Error('Queue is at capacity');
    }
    this.buffer.push(event);
  }

  drain(): EventPayload[] {
    const events = this.buffer;
    this.buffer = [];
    return events;
  }

  size(): number {
    return this.buffer.length;
  }

  isEmpty(): boolean {
    return this.buffer.length === 0;
  }
}
