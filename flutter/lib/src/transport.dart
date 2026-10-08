import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'event.dart';

class EventBatchResponse {
  const EventBatchResponse({required this.accepted, required this.errors});

  factory EventBatchResponse.fromJson(Map<String, Object?> json) {
    final errors = (json['errors'] as List<Object?>?) ?? const [];
    return EventBatchResponse(
      accepted: (json['accepted'] as num?)?.toInt() ?? 0,
      errors: errors
          .map((e) => EventBatchError.fromJson(e! as Map<String, Object?>))
          .toList(),
    );
  }

  final int accepted;
  final List<EventBatchError> errors;
}

class TransportError implements Exception {
  const TransportError(this.message, {this.statusCode, this.retryAfter});

  final String message;

  /// HTTP status, or null when the request never got a response.
  final int? statusCode;

  /// Seconds from the `Retry-After` header on a 429.
  final int? retryAfter;

  @override
  String toString() => 'TransportError($statusCode): $message';
}

/// Sends event batches to `POST {endpoint}/events`.
class Transport {
  Transport({
    required String endpoint,
    required String apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  })  : _uri = Uri.parse('$endpoint/events'),
        _apiKey = apiKey,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final Uri _uri;
  final String _apiKey;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  /// Returns the API response for 201, 207 and 422. Throws [TransportError]
  /// for everything else.
  Future<EventBatchResponse> send(List<MobyBeaconEvent> events) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            _uri,
            headers: {
              'Content-Type': 'application/json',
              'X-API-Key': _apiKey,
            },
            body: jsonEncode(
                {'events': events.map((event) => event.toJson()).toList()}),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const TransportError('Request timed out');
    } catch (error) {
      throw TransportError('Network error: $error');
    }

    final status = response.statusCode;
    if (status == 429) {
      throw TransportError(
        'Rate limited',
        statusCode: 429,
        retryAfter: _retryAfterSeconds(response.headers),
      );
    }
    if (status >= 500) {
      throw TransportError('Server error: $status', statusCode: status);
    }
    if (status >= 300 && status < 400) {
      throw TransportError(
        'Unexpected redirect ($status); check the endpoint URL',
        statusCode: status,
      );
    }
    if (status == 201 || status == 207 || status == 422) {
      try {
        return EventBatchResponse.fromJson(
            jsonDecode(response.body) as Map<String, Object?>);
      } catch (_) {
        // The server took the batch; an unreadable body carries no
        // per-event errors to report.
        return const EventBatchResponse(accepted: 0, errors: []);
      }
    }
    throw TransportError('Client error: $status', statusCode: status);
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// Seconds to wait from `Retry-After`, or from the longest of the
/// `Retry-After-<name>` headers that NestJS named throttlers send instead.
/// Header names arrive lowercased from `package:http`.
int? _retryAfterSeconds(Map<String, String> headers) {
  final plain = int.tryParse(headers['retry-after'] ?? '');
  if (plain != null) return plain;
  int? longest;
  for (final MapEntry(:key, :value) in headers.entries) {
    if (!key.startsWith('retry-after-')) continue;
    final seconds = int.tryParse(value);
    if (seconds != null && (longest == null || seconds > longest)) {
      longest = seconds;
    }
  }
  return longest;
}
