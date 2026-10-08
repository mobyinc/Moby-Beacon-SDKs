import 'errors.dart';
import 'validate.dart' show maxFieldLength;

typedef MobyBeaconErrorHandler = void Function(MobyBeaconError error);

class MobyBeaconConfig {
  MobyBeaconConfig({
    required String endpoint,
    required this.apiKey,
    required this.userId,
    this.flushInterval = const Duration(seconds: 5),
    this.batchSize = 10,
    this.maxQueueSize = 10000,
    this.onError,
  }) : endpoint = endpoint.replaceAll(RegExp(r'/+$'), '') {
    final uri = Uri.tryParse(this.endpoint);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      throw ArgumentError.value(
          endpoint, 'endpoint', 'must be an absolute http(s) URL');
    }
    if (apiKey.trim().isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'must not be empty');
    }
    if (userId.trim().isEmpty) {
      throw ArgumentError.value(userId, 'userId', 'must not be empty');
    }
    if (userId.length > maxFieldLength) {
      throw ArgumentError.value(
          userId, 'userId', 'must be at most $maxFieldLength characters');
    }
    if (userId.contains('\u0000')) {
      throw ArgumentError.value(
          userId, 'userId', 'must not contain NUL characters');
    }
    if (flushInterval <= Duration.zero) {
      throw ArgumentError.value(
          flushInterval, 'flushInterval', 'must be positive');
    }
    if (batchSize < 1) {
      throw ArgumentError.value(batchSize, 'batchSize', 'must be at least 1');
    }
    if (maxQueueSize < 1) {
      throw ArgumentError.value(
          maxQueueSize, 'maxQueueSize', 'must be at least 1');
    }
  }

  /// API base URL, without a trailing slash. Events are sent to
  /// `{endpoint}/events`.
  final String endpoint;

  /// Ingest API key, sent as the `X-API-Key` header.
  final String apiKey;

  /// Default user ID attached to every event.
  final String userId;

  /// Time between automatic flushes when sends are succeeding.
  final Duration flushInterval;

  /// Flush as soon as this many events are queued.
  final int batchSize;

  /// Maximum number of events held on disk. New events are rejected when full.
  final int maxQueueSize;

  /// Called when events are rejected, dropped, or queued for retry (see
  /// [MobyBeaconError.willRetry]). Exceptions it throws are ignored. Without
  /// it, failures are silent.
  final MobyBeaconErrorHandler? onError;
}
