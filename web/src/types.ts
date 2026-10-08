// Wire types for POST /events, kept in sync with the Moby Beacon API.

export interface EventPayload {
  userId: string;
  category: string;
  action: string;
  timestamp?: string;
  details?: Record<string, string | number | boolean | null>;
}

export interface EventBatchRequest {
  events: EventPayload[];
}

export interface EventBatchError {
  index: number;
  message: string;
}

export interface EventBatchResponse {
  accepted: number;
  errors: EventBatchError[];
}
