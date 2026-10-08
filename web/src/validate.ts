import { EventPayload } from './types';

export function validateEvent(event: EventPayload): void {
  if (!event.userId || typeof event.userId !== 'string') {
    throw new Error('userId is required and must be a non-empty string');
  }

  if (!event.category || typeof event.category !== 'string') {
    throw new Error('category is required and must be a non-empty string');
  }

  if (!event.action || typeof event.action !== 'string') {
    throw new Error('action is required and must be a non-empty string');
  }

  if (event.details !== undefined) {
    if (
      typeof event.details !== 'object' ||
      event.details === null ||
      Array.isArray(event.details)
    ) {
      throw new Error('details must be a flat object');
    }
    for (const [key, value] of Object.entries(event.details)) {
      if (value !== null && typeof value === 'object') {
        throw new Error(
          `details.${key} must be a string, number, boolean, or null — not a nested object or array`,
        );
      }
    }
  }

  if (event.timestamp !== undefined && typeof event.timestamp !== 'string') {
    throw new Error('timestamp must be a string');
  }
}
