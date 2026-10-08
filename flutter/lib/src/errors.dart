import 'event.dart';

enum MobyBeaconErrorType { network, server, auth, validation }

/// Reported through `MobyBeaconConfig.onError`.
class MobyBeaconError {
  const MobyBeaconError({
    required this.type,
    required this.message,
    required this.events,
    this.errors,
    this.willRetry = false,
  });

  final MobyBeaconErrorType type;
  final String message;

  /// The events affected. For server validation errors this is the full sent
  /// batch, so [errors] indexes line up with it.
  final List<MobyBeaconEvent> events;

  /// Per-event errors from a 207/422 response.
  final List<EventBatchError>? errors;

  /// True when [events] are still queued and will be retried.
  final bool willRetry;

  @override
  String toString() => 'MobyBeaconError(${type.name}): $message';
}
