import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moby_beacon/moby_beacon.dart';
import 'package:moby_beacon/src/event_store.dart';
import 'package:moby_beacon/src/moby_beacon.dart'
    show maxEventsPerRequest, maxRequestBytes;
import 'package:moby_beacon/src/transport.dart';

import 'support/fixed_random.dart';
import 'support/memory_queue_storage.dart';

http.Response accepted() =>
    http.Response(jsonEncode({'accepted': 1, 'errors': <Object>[]}), 201);

Map<String, Object?> storedEvent(String action) => {
      'userId': 'user-1',
      'category': 'screen',
      'action': action,
      'timestamp': '2026-10-06T09:00:00.000Z',
    };

/// Builds a version 1 queue file holding [events].
String v1(List<Object?> events) => jsonEncode({'v': 1, 'events': events});

/// Actions of the events in a stored version 1 queue file.
List<String> storedActions(String? contents) {
  final file = jsonDecode(contents!) as Map<String, Object?>;
  expect(file['v'], 1);
  return (file['events']! as List<Object?>)
      .map((e) => (e! as Map<String, Object?>)['action']! as String)
      .toList();
}

/// Transport whose send throws something other than a [TransportError].
class ThrowingTransport extends Transport {
  ThrowingTransport()
      : super(
          endpoint: 'https://beacon.test',
          apiKey: 'key-123',
          client: MockClient((_) async => accepted()),
        );

  int sends = 0;

  @override
  Future<EventBatchResponse> send(List<MobyBeaconEvent> events) async {
    sends++;
    throw StateError('boom');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryQueueStorage storage;
  late List<List<Map<String, Object?>>> requests;
  late List<int> requestBytes;
  late List<MobyBeaconError> errors;
  late Future<http.Response> Function(http.Request request) respond;
  final beacons = <MobyBeacon>[];

  setUp(() {
    storage = MemoryQueueStorage();
    requests = [];
    requestBytes = [];
    errors = [];
    respond = (_) async => accepted();
  });

  /// Runs [body] in fake time, then disposes every beacon it started so no
  /// lifecycle observer outlives the test. (Disposal removes the observer
  /// synchronously, even if a send is still held open.)
  void run(void Function(FakeAsync async) body) {
    fakeAsync((async) {
      try {
        body(async);
      } finally {
        for (final beacon in beacons) {
          unawaited(beacon.dispose());
        }
        beacons.clear();
        async.flushMicrotasks();
        // A dispose held open by a pending send never finishes.
        MobyBeacon.resetLiveInstanceForTesting();
      }
    });
  }

  /// Delivers a lifecycle change through the binding, as the engine would.
  void setLifecycle(AppLifecycleState state) =>
      // ignore: invalid_use_of_protected_member
      WidgetsBinding.instance.handleAppLifecycleStateChanged(state);

  /// Creates a beacon with in-memory storage, a mock HTTP client, a fixed
  /// clock and no jitter.
  Future<MobyBeacon> create({
    int batchSize = 10,
    int maxQueueSize = 100,
    MobyBeaconErrorHandler? onError,
    Transport? transport,
  }) =>
      MobyBeacon.createWith(
        config: MobyBeaconConfig(
          endpoint: 'https://beacon.test',
          apiKey: 'key-123',
          userId: 'user-1',
          batchSize: batchSize,
          maxQueueSize: maxQueueSize,
          onError: onError ?? errors.add,
        ),
        store: EventStore(storage: storage, maxSize: maxQueueSize),
        transport: transport ??
            Transport(
              endpoint: 'https://beacon.test',
              apiKey: 'key-123',
              client: MockClient((request) {
                final body = jsonDecode(request.body) as Map<String, Object?>;
                requests.add((body['events']! as List<Object?>)
                    .cast<Map<String, Object?>>());
                requestBytes.add(utf8.encode(request.body).length);
                return respond(request);
              }),
            ),
        clock: () => DateTime.utc(2026, 10, 7, 12),
        random: FixedRandom(0),
      );

  /// [create], run to completion inside [async].
  MobyBeacon start(
    FakeAsync async, {
    int batchSize = 10,
    int maxQueueSize = 100,
    MobyBeaconErrorHandler? onError,
    Transport? transport,
  }) {
    late MobyBeacon beacon;
    unawaited(create(
      batchSize: batchSize,
      maxQueueSize: maxQueueSize,
      onError: onError,
      transport: transport,
    ).then((created) => beacon = created));
    async.flushMicrotasks();
    beacons.add(beacon);
    return beacon;
  }

  List<String> actionsOf(List<Map<String, Object?>> events) =>
      events.map((e) => e['action']! as String).toList();

  List<String> sentActions(int requestIndex) =>
      actionsOf(requests[requestIndex]);

  group('track', () {
    test('queues an event with the default userId and a UTC timestamp', () {
      run((async) {
        final beacon = start(async);
        beacon.track('screen', 'view', details: {'name': 'home'});
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(requests.single.single, {
          'userId': 'user-1',
          'category': 'screen',
          'action': 'view',
          'timestamp': '2026-10-07T12:00:00.000Z',
          'details': {'name': 'home'},
        });
      });
    });

    test('replaces a lone surrogate from truncated text', () {
      run((async) {
        final beacon = start(async);
        beacon.track('survey', 'answer',
            details: {'text': 'I feel \u{1F600}'.substring(0, 8)});
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(errors, isEmpty);
        expect(requests.single.single['details'], {'text': 'I feel \uFFFD'});
      });
    });

    test('applies userId and timestamp overrides', () {
      run((async) {
        final beacon = start(async);
        beacon.track('screen', 'view',
            userId: 'user-2', timestamp: DateTime.utc(2026, 1, 2, 3));
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(requests.single.single['userId'], 'user-2');
        expect(requests.single.single['timestamp'], '2026-01-02T03:00:00.000Z');
      });
    });

    test('reports invalid events instead of throwing', () {
      run((async) {
        final beacon = start(async);
        beacon.track('', 'view');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(errors.single.type, MobyBeaconErrorType.validation);
        expect(errors.single.message,
            'category is required and must be a non-empty string');
        expect(errors.single.willRetry, isFalse);
        expect(requests, isEmpty);
      });
    });

    test('reports a full queue instead of throwing', () {
      run((async) {
        final beacon = start(async, maxQueueSize: 1);
        beacon
          ..track('screen', 'a')
          ..track('screen', 'b');

        expect(errors.single.type, MobyBeaconErrorType.validation);
        expect(errors.single.message, 'Queue is at capacity');
        expect(errors.single.events.single.action, 'b');
      });
    });

    test('a throwing onError does not break tracking', () {
      run((async) {
        final beacon =
            start(async, onError: (_) => throw StateError('handler bug'));
        beacon
          ..track('', 'view')
          ..track('screen', 'view');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(requests.single.single['action'], 'view');
      });
    });
  });

  group('automatic flushing', () {
    test('flushes when batchSize is reached', () {
      run((async) {
        final beacon = start(async, batchSize: 3);
        beacon
          ..track('screen', 'a')
          ..track('screen', 'b');
        async.flushMicrotasks();
        expect(requests, isEmpty);

        beacon.track('screen', 'c');
        async.flushMicrotasks();
        expect(sentActions(0), ['a', 'b', 'c']);
      });
    });

    test('flushes when the timer fires', () {
      run((async) {
        final beacon = start(async);
        beacon.track('screen', 'a');
        async.elapse(const Duration(seconds: 4));
        expect(requests, isEmpty);

        async.elapse(const Duration(seconds: 1));
        expect(sentActions(0), ['a']);
      });
    });

    test('a flush of an empty queue does not block later flushes', () {
      run((async) {
        final beacon = start(async);
        unawaited(beacon.flush());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        expect(requests, isEmpty);

        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();
        expect(sentActions(0), ['a']);
      });
    });

    test('sends events persisted by a previous instance on start', () {
      run((async) {
        storage = MemoryQueueStorage(v1([storedEvent('left-over')]));
        start(async);

        expect(sentActions(0), ['left-over']);
      });
    });

    test('reports an unreadable persisted queue on start', () {
      run((async) {
        storage = MemoryQueueStorage('{not json');
        start(async);

        expect(errors.single.type, MobyBeaconErrorType.validation);
        expect(errors.single.willRetry, isFalse);
        expect(storage.quarantined, isTrue);
      });
    });

    test('sends a large backlog in bounded requests, in order', () {
      run((async) {
        final beacon = start(async, batchSize: 5000, maxQueueSize: 2500);
        for (var i = 0; i < 2500; i++) {
          beacon.track('screen', 'e$i');
        }
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(
            requests.expand(actionsOf), [for (var i = 0; i < 2500; i++) 'e$i']);
        expect(requests.length, greaterThan(1));
        for (final request in requests) {
          expect(request.length, lessThanOrEqualTo(maxEventsPerRequest));
        }
        for (final bytes in requestBytes) {
          expect(bytes, lessThanOrEqualTo(maxRequestBytes + 64));
        }
        expect(errors, isEmpty);
      });
    });

    test('a flush requested mid-flight sends events tracked meanwhile', () {
      run((async) {
        final firstResponse = Completer<http.Response>();
        respond = (_) => requests.length == 1
            ? firstResponse.future
            : Future.value(accepted());
        final beacon = start(async);

        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();
        beacon.track('screen', 'b');
        unawaited(beacon.flush());
        async.flushMicrotasks();
        expect(requests, hasLength(1));

        firstResponse.complete(accepted());
        async.flushMicrotasks();
        expect(sentActions(0), ['a']);
        expect(sentActions(1), ['b']);
        expect(requests, hasLength(2));
      });
    });
  });

  group('failures', () {
    test('network failure keeps events and backs off the timer', () {
      run((async) {
        respond = (_) async => throw http.ClientException('offline');
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(errors.single.type, MobyBeaconErrorType.network);
        expect(errors.single.willRetry, isTrue);
        expect(requests, hasLength(1));

        // Backoff after one failure is 10s, not the 5s interval.
        async.elapse(const Duration(seconds: 5));
        expect(requests, hasLength(1));

        respond = (_) async => accepted();
        async.elapse(const Duration(seconds: 5));
        expect(requests, hasLength(2));
        expect(sentActions(1), ['a']);

        // Success resets the timer to the normal interval.
        beacon.track('screen', 'b');
        async.elapse(const Duration(seconds: 5));
        expect(sentActions(2), ['b']);
      });
    });

    test('429 waits for Retry-After before the next attempt', () {
      run((async) {
        respond =
            (_) async => http.Response('', 429, headers: {'retry-after': '30'});
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(errors.single.type, MobyBeaconErrorType.server);
        expect(errors.single.willRetry, isTrue);

        respond = (_) async => accepted();
        async.elapse(const Duration(seconds: 29));
        expect(requests, hasLength(1));
        async.elapse(const Duration(seconds: 1));
        expect(requests, hasLength(2));
      });
    });

    test('5xx keeps events for retry', () {
      run((async) {
        respond = (_) async => http.Response('', 503);
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(errors.single.type, MobyBeaconErrorType.server);
        expect(errors.single.willRetry, isTrue);
        expect(errors.single.events.single.action, 'a');
      });
    });

    test('408 keeps events for retry with backoff', () {
      run((async) {
        respond = (_) async => http.Response('', 408);
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(errors.single.type, MobyBeaconErrorType.server);
        expect(errors.single.willRetry, isTrue);
        expect(errors.single.events.single.action, 'a');

        respond = (_) async => accepted();
        async.elapse(const Duration(seconds: 5));
        expect(requests, hasLength(1), reason: 'backed off to 10s');
        async.elapse(const Duration(seconds: 5));
        expect(sentActions(1), ['a']);
      });
    });

    test('207 drops the batch and reports per-event errors', () {
      run((async) {
        respond = (_) async => http.Response(
            jsonEncode({
              'accepted': 1,
              'errors': [
                {'index': 1, 'message': 'details must be a flat object'},
              ],
            }),
            207);
        final beacon = start(async);
        beacon
          ..track('screen', 'a')
          ..track('screen', 'b');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        final error = errors.single;
        expect(error.type, MobyBeaconErrorType.validation);
        expect(error.willRetry, isFalse);
        expect(error.events.map((e) => e.action), ['a', 'b']);
        expect(error.errors!.single.index, 1);

        unawaited(beacon.flush());
        async.flushMicrotasks();
        expect(requests, hasLength(1));
      });
    });

    test('401 keeps events and retries at the backoff ceiling', () {
      run((async) {
        respond = (_) async => http.Response('', 401);
        final beacon = start(async, batchSize: 3);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(errors.single.type, MobyBeaconErrorType.auth);
        expect(errors.single.willRetry, isTrue);
        expect(errors.single.events.single.action, 'a');

        // Tracking past batchSize does not retry early.
        beacon
          ..track('screen', 'b')
          ..track('screen', 'c');
        async.elapse(const Duration(minutes: 4, seconds: 59));
        expect(requests, hasLength(1));

        respond = (_) async => accepted(); // The key works again.
        async.elapse(const Duration(seconds: 1));
        expect(requests, hasLength(2));
        expect(sentActions(1), ['a', 'b', 'c']);
        expect(errors, hasLength(1));
      });
    });

    test('403 keeps events and reports an auth error', () {
      run((async) {
        respond = (_) async => http.Response('', 403);
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(errors.single.type, MobyBeaconErrorType.auth);
        expect(errors.single.willRetry, isTrue);

        respond = (_) async => accepted();
        async.elapse(const Duration(minutes: 5));
        expect(sentActions(1), ['a']);
      });
    });

    test('404 keeps events and reports a server error', () {
      run((async) {
        respond = (_) async => http.Response('', 404);
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(errors.single.type, MobyBeaconErrorType.server);
        expect(errors.single.willRetry, isTrue);
        expect(errors.single.message, 'Client error: 404');

        respond = (_) async => accepted();
        async.elapse(const Duration(minutes: 5));
        expect(sentActions(1), ['a']);
      });
    });

    for (final status in [400, 200, 204]) {
      test('unexpected status $status keeps events as a server error', () {
        run((async) {
          respond = (_) async => http.Response('', status);
          final beacon = start(async);
          beacon.track('screen', 'a');
          unawaited(beacon.flush());
          async.flushMicrotasks();

          expect(errors.single.type, MobyBeaconErrorType.server);
          expect(errors.single.willRetry, isTrue);
          expect(errors.single.events.single.action, 'a');
        });
      });
    }

    test('a redirect keeps events and passes the message through', () {
      run((async) {
        respond = (_) async => http.Response('', 301,
            headers: {'location': 'https://elsewhere.test/events'});
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(errors.single.type, MobyBeaconErrorType.server);
        expect(errors.single.willRetry, isTrue);
        expect(errors.single.message, contains('Unexpected redirect'));
        expect(errors.single.events.single.action, 'a');

        respond = (_) async => accepted();
        async.elapse(const Duration(minutes: 5));
        expect(sentActions(1), ['a']);
      });
    });

    test('413 for a multi-event batch splits it and delivers everything', () {
      run((async) {
        final delivered = <String>[];
        respond = (request) async {
          final events = requests.last;
          if (events.length > 3) return http.Response('', 413);
          delivered.addAll(actionsOf(events));
          return accepted();
        };
        final beacon = start(async, batchSize: 100);
        for (var i = 0; i < 10; i++) {
          beacon.track('screen', 'e$i');
        }
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(delivered, [for (var i = 0; i < 10; i++) 'e$i']);
        expect(errors, isEmpty);
        expect(requests.first, hasLength(10));
        for (final request in requests.skip(1)) {
          expect(request.length, lessThan(10));
        }
      });
    });

    test('413 for a single event drops it and delivers the rest', () {
      run((async) {
        final delivered = <String>[];
        respond = (request) async {
          final events = requests.last;
          if (actionsOf(events).contains('big')) {
            return http.Response('', 413);
          }
          delivered.addAll(actionsOf(events));
          return accepted();
        };
        final beacon = start(async);
        beacon
          ..track('screen', 'a')
          ..track('screen', 'big')
          ..track('screen', 'c');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(delivered, ['a', 'c']);
        final error = errors.single;
        expect(error.type, MobyBeaconErrorType.validation);
        expect(error.message, 'Event is larger than the API accepts');
        expect(error.willRetry, isFalse);
        expect(error.events.single.action, 'big');

        final sent = requests.length;
        unawaited(beacon.flush());
        async.flushMicrotasks();
        expect(requests, hasLength(sent), reason: 'nothing left to send');
      });
    });
  });

  group('lifecycle', () {
    test('paused persists and flushes', () {
      run((async) {
        final beacon = start(async);
        beacon.track('screen', 'a');
        setLifecycle(AppLifecycleState.paused);
        async.flushMicrotasks();

        expect(sentActions(0), ['a']);
        expect(storedActions(storage.contents), isEmpty);
      });
    });

    test('hidden persists and flushes', () {
      run((async) {
        final beacon = start(async);
        beacon.track('screen', 'a');
        setLifecycle(AppLifecycleState.hidden);
        async.flushMicrotasks();

        expect(sentActions(0), ['a']);
        expect(storedActions(storage.contents), isEmpty);
      });
    });

    test('resumed flushes immediately and resets backoff', () {
      run((async) {
        respond = (_) async => throw http.ClientException('offline');
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();
        unawaited(beacon.flush());
        async.flushMicrotasks();
        expect(requests, hasLength(2), reason: 'two failures so far');

        setLifecycle(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(requests, hasLength(3), reason: 'resume flushes immediately');

        // Reset to zero, then one failure: next attempt in 10s, not 40s.
        async.elapse(const Duration(seconds: 10));
        expect(requests, hasLength(4));
      });
    });

    test('resumed reads a backlog that was locked at launch and sends it', () {
      run((async) {
        storage = MemoryQueueStorage(v1([storedEvent('stored')]))
          ..readError = const FileSystemException('locked');
        start(async);
        async.elapse(const Duration(seconds: 5));
        expect(requests, isEmpty);

        storage.readError = null;
        setLifecycle(AppLifecycleState.resumed);
        async.flushMicrotasks();

        expect(sentActions(0), ['stored']);
        expect(storedActions(storage.contents), isEmpty);
        expect(errors, isEmpty);
      });
    });

    test('dispose flushes, then track and flush do nothing', () {
      run((async) {
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.dispose());
        async.flushMicrotasks();
        expect(sentActions(0), ['a']);

        beacon.track('screen', 'b');
        unawaited(beacon.flush());
        async.elapse(const Duration(minutes: 10));
        expect(requests, hasLength(1));
        expect(storedActions(storage.contents), isEmpty,
            reason: 'b was never queued');
      });
    });

    test('dispose keeps unsent events on disk', () {
      run((async) {
        respond = (_) async => throw http.ClientException('offline');
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.dispose());
        async.flushMicrotasks();

        expect(storedActions(storage.contents), ['a']);
      });
    });
  });

  group('backoff', () {
    test('tracking past batchSize while offline waits for the backoff', () {
      run((async) {
        respond = (_) async => throw http.ClientException('offline');
        final beacon = start(async, batchSize: 3);
        beacon
          ..track('screen', 'a')
          ..track('screen', 'b')
          ..track('screen', 'c');
        async.flushMicrotasks();
        expect(requests, hasLength(1));

        for (var i = 0; i < 50; i++) {
          beacon.track('screen', 'more$i');
          async.elapse(const Duration(milliseconds: 100));
        }
        expect(requests, hasLength(1), reason: 'still inside the 10s backoff');

        async.elapse(const Duration(seconds: 5));
        expect(requests, hasLength(2), reason: 'the backoff timer fired');
      });
    });

    test('tracking past batchSize honours Retry-After', () {
      run((async) {
        respond =
            (_) async => http.Response('', 429, headers: {'retry-after': '60'});
        final beacon = start(async, batchSize: 3);
        beacon
          ..track('screen', 'a')
          ..track('screen', 'b')
          ..track('screen', 'c');
        async.flushMicrotasks();
        expect(requests, hasLength(1));

        for (var i = 0; i < 30; i++) {
          beacon.track('screen', 'more$i');
          async.elapse(const Duration(seconds: 1));
        }
        expect(requests, hasLength(1));

        async.elapse(const Duration(seconds: 30));
        expect(requests, hasLength(2));
      });
    });

    test('a server answer after network failures restores the interval', () {
      run((async) {
        respond = (_) async => throw http.ClientException('offline');
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        expect(requests, hasLength(2), reason: 'two network failures');

        // The server rejects the lone event as too large: a real answer.
        respond = (_) async => http.Response('', 413);
        async.elapse(const Duration(seconds: 20));
        expect(requests, hasLength(3));
        expect(errors.last.type, MobyBeaconErrorType.validation);

        respond = (_) async => accepted();
        beacon.track('screen', 'b');
        async.elapse(const Duration(seconds: 5));
        expect(sentActions(3), ['b']);
      });
    });

    test('a latched flush is discarded after a transient failure', () {
      run((async) {
        final firstResponse = Completer<http.Response>();
        respond = (_) => firstResponse.future;
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();
        beacon.track('screen', 'b');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        firstResponse.complete(http.Response('', 503));
        async.flushMicrotasks();
        expect(requests, hasLength(1));
      });
    });

    test('an unexpected exception is treated as a network failure', () {
      run((async) {
        final transport = ThrowingTransport();
        final beacon = start(async, transport: transport);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(transport.sends, 1);
        expect(errors.single.type, MobyBeaconErrorType.network);
        expect(errors.single.willRetry, isTrue);
        expect(errors.single.events.single.action, 'a');

        async.elapse(const Duration(seconds: 5));
        expect(transport.sends, 1, reason: 'backed off to 10s');
        async.elapse(const Duration(seconds: 5));
        expect(transport.sends, 2, reason: 'the event was kept');
      });
    });
  });

  group('batching', () {
    test('the batch size recovers after a 413 once the queue drains', () {
      run((async) {
        respond = (request) async =>
            requests.last.length > 3 ? http.Response('', 413) : accepted();
        final beacon = start(async, batchSize: 100);
        for (var i = 0; i < 10; i++) {
          beacon.track('screen', 'e$i');
        }
        unawaited(beacon.flush());
        async.flushMicrotasks();
        expect(errors, isEmpty);

        respond = (_) async => accepted();
        final before = requests.length;
        for (var i = 0; i < 10; i++) {
          beacon.track('screen', 'f$i');
        }
        unawaited(beacon.flush());
        async.flushMicrotasks();
        expect(requests, hasLength(before + 1));
        expect(requests.last, hasLength(10));
      });
    });

    test('the batch size recovers after dropping an oversized event', () {
      run((async) {
        respond = (request) async => actionsOf(requests.last).contains('big')
            ? http.Response('', 413)
            : accepted();
        final beacon = start(async, batchSize: 100);
        for (final action in ['a', 'big', 'c', 'd', 'e']) {
          beacon.track('screen', action);
        }
        unawaited(beacon.flush());
        async.flushMicrotasks();

        expect(errors.single.events.single.action, 'big');
        expect(sentActions(requests.length - 1), ['c', 'd', 'e']);
      });
    });

    test('a backlog read mid-send is appended and sent in order', () {
      run((async) {
        storage = MemoryQueueStorage(v1([storedEvent('stored')]))
          ..readError = const FileSystemException('locked');
        final firstResponse = Completer<http.Response>();
        respond = (_) => requests.length == 1
            ? firstResponse.future
            : Future.value(accepted());
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();
        expect(sentActions(0), ['a']);

        storage.readError = null;
        beacon.track('screen', 'b'); // Its write reads the backlog.
        async.flushMicrotasks();

        firstResponse.complete(accepted());
        async.flushMicrotasks();
        expect(sentActions(1), ['b', 'stored']);
        expect(requests, hasLength(2));
        expect(storedActions(storage.contents), isEmpty);
      });
    });
  });

  group('flush and dispose', () {
    test('awaiting flush during a flush waits for events queued meanwhile', () {
      run((async) {
        final firstResponse = Completer<http.Response>();
        var flushDone = false;
        bool? doneWhenSecondSent;
        respond = (_) {
          if (requests.length == 1) return firstResponse.future;
          doneWhenSecondSent = flushDone;
          return Future.value(accepted());
        };
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        beacon.track('screen', 'b');
        unawaited(beacon.flush().then((_) => flushDone = true));
        async.flushMicrotasks();
        expect(flushDone, isFalse);

        firstResponse.complete(accepted());
        async.flushMicrotasks();
        expect(sentActions(1), ['b']);
        expect(doneWhenSecondSent, isFalse);
        expect(flushDone, isTrue);
      });
    });

    test('dispose waits for an in-flight send, then sends the rest', () {
      run((async) {
        final firstResponse = Completer<http.Response>();
        respond = (_) => requests.length == 1
            ? firstResponse.future
            : Future.value(accepted());
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();
        beacon.track('screen', 'b');

        var disposed = false;
        unawaited(beacon.dispose().then((_) => disposed = true));
        async.flushMicrotasks();
        expect(disposed, isFalse);
        expect(requests, hasLength(1));

        firstResponse.complete(accepted());
        async.flushMicrotasks();
        expect(sentActions(1), ['b']);
        expect(disposed, isTrue);
        expect(storedActions(storage.contents), isEmpty);
      });
    });

    test('a second dispose completes only when the first does', () {
      run((async) {
        final response = Completer<http.Response>();
        respond = (_) => response.future;
        final beacon = start(async);
        beacon.track('screen', 'a');

        var firstDone = false;
        var secondDone = false;
        unawaited(beacon.dispose().then((_) => firstDone = true));
        async.flushMicrotasks();
        unawaited(beacon.dispose().then((_) => secondDone = true));
        async.flushMicrotasks();
        expect(requests, hasLength(1));
        expect(secondDone, isFalse);

        response.complete(accepted());
        async.flushMicrotasks();
        expect(firstDone, isTrue);
        expect(secondDone, isTrue);
      });
    });

    test('flush during dispose does not start another send', () {
      run((async) {
        respond = (_) async => throw http.ClientException('offline');
        storage.writeGate = Completer<void>();
        final beacon = start(async);
        beacon.track('screen', 'a');

        var disposed = false;
        unawaited(beacon.dispose().then((_) => disposed = true));
        async.flushMicrotasks();
        expect(requests, hasLength(1));
        expect(disposed, isFalse, reason: 'waiting for the held write');

        unawaited(beacon.flush());
        async.flushMicrotasks();
        expect(requests, hasLength(1));

        storage.writeGate!.complete();
        async.flushMicrotasks();
        expect(disposed, isTrue);
        expect(requests, hasLength(1));
        expect(storedActions(storage.contents), ['a']);
      });
    });

    test('only one instance can be live until dispose completes', () {
      run((async) {
        final response = Completer<http.Response>();
        respond = (_) => response.future;
        final first = start(async);

        Object? error;
        unawaited(create().then((_) {}, onError: (Object e) => error = e));
        async.flushMicrotasks();
        expect(
            error,
            isA<StateError>().having(
                (e) => e.message, 'message', contains('already running')));

        first.track('screen', 'a');
        unawaited(first.dispose());
        async.flushMicrotasks();
        error = null;
        unawaited(create().then((_) {}, onError: (Object e) => error = e));
        async.flushMicrotasks();
        expect(error, isA<StateError>(), reason: 'still disposing');

        response.complete(accepted());
        async.flushMicrotasks();
        start(async); // Dispose finished, so this succeeds.
      });
    });

    test('dispose leaves no timers behind', () {
      run((async) {
        respond = (_) async => throw http.ClientException('offline');
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.flush());
        async.flushMicrotasks();

        unawaited(beacon.dispose());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('lifecycle changes after dispose do nothing', () {
      run((async) {
        respond = (_) async => throw http.ClientException('offline');
        final beacon = start(async);
        beacon.track('screen', 'a');
        unawaited(beacon.dispose());
        async.flushMicrotasks();
        final sent = requests.length;
        final writes = storage.writeCount;

        setLifecycle(AppLifecycleState.paused);
        setLifecycle(AppLifecycleState.resumed);
        async.elapse(const Duration(minutes: 10));
        expect(requests, hasLength(sent));
        expect(storage.writeCount, writes);
      });
    });
  });
}
