import 'package:flutter_test/flutter_test.dart';
import 'package:moby_beacon/src/event.dart';

void main() {
  test('toJson serializes timestamp as UTC ISO 8601', () {
    final event = MobyBeaconEvent(
      userId: 'user-1',
      category: 'screen',
      action: 'view',
      timestamp: DateTime.utc(2026, 10, 7, 12, 30),
    );
    expect(event.toJson(), {
      'userId': 'user-1',
      'category': 'screen',
      'action': 'view',
      'timestamp': '2026-10-07T12:30:00.000Z',
    });
  });

  test('toJson includes details when present', () {
    final event = MobyBeaconEvent(
      userId: 'user-1',
      category: 'survey',
      action: 'answer',
      timestamp: DateTime.utc(2026, 10, 7),
      details: const {'question': 3, 'value': 'agree'},
    );
    expect(event.toJson()['details'], {'question': 3, 'value': 'agree'});
  });

  test('fromJson round-trips toJson', () {
    final event = MobyBeaconEvent(
      userId: 'user-1',
      category: 'survey',
      action: 'answer',
      timestamp: DateTime.utc(2026, 10, 7, 8),
      details: const {'question': 3, 'skipped': false, 'note': null},
    );
    expect(MobyBeaconEvent.fromJson(event.toJson()).toJson(), event.toJson());
  });

  test('EventBatchError.fromJson reads index and message', () {
    final error =
        EventBatchError.fromJson(const {'index': 2, 'message': 'bad'});
    expect(error.index, 2);
    expect(error.message, 'bad');
  });

  test('fromJson produces unmodifiable details', () {
    final event = MobyBeaconEvent.fromJson(const {
      'userId': 'user-1',
      'category': 'survey',
      'action': 'answer',
      'timestamp': '2026-10-07T08:00:00.000Z',
      'details': {'question': 3},
    });
    expect(() => event.details!['question'] = 4, throwsUnsupportedError);
  });
}
