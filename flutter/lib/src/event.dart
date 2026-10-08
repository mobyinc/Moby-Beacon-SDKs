import 'package:flutter/foundation.dart';

/// A single study event, in the shape sent to `POST /events`.
@immutable
class MobyBeaconEvent {
  const MobyBeaconEvent({
    required this.userId,
    required this.category,
    required this.action,
    required this.timestamp,
    this.details,
  });

  factory MobyBeaconEvent.fromJson(Map<String, Object?> json) {
    final details = json['details'];
    return MobyBeaconEvent(
      userId: json['userId']! as String,
      category: json['category']! as String,
      action: json['action']! as String,
      timestamp: DateTime.parse(json['timestamp']! as String),
      details: details == null
          ? null
          : Map<String, Object?>.unmodifiable(details as Map<String, Object?>),
    );
  }

  final String userId;
  final String category;
  final String action;
  final DateTime timestamp;
  final Map<String, Object?>? details;

  Map<String, Object?> toJson() => {
        'userId': userId,
        'category': category,
        'action': action,
        'timestamp': timestamp.toUtc().toIso8601String(),
        if (details != null) 'details': details,
      };
}

/// A per-event rejection returned by the API in a 207 or 422 response.
@immutable
class EventBatchError {
  const EventBatchError({required this.index, required this.message});

  factory EventBatchError.fromJson(Map<String, Object?> json) =>
      EventBatchError(
        index: (json['index']! as num).toInt(),
        message: json['message']! as String,
      );

  /// Position of the rejected event in the sent batch.
  final int index;
  final String message;
}
