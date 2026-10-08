import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moby_beacon/src/event.dart';
import 'package:moby_beacon/src/event_store.dart';
import 'package:moby_beacon/src/queue_storage.dart';

import 'support/memory_queue_storage.dart';

MobyBeaconEvent event(String action) => MobyBeaconEvent(
      userId: 'user-1',
      category: 'test',
      action: action,
      timestamp: DateTime.utc(2026, 10, 7),
    );

List<String> actions(List<MobyBeaconEvent> events) =>
    events.map((e) => e.action).toList();

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

/// Lets pending microtasks and zero-delay timers run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('EventStore', () {
    test('behaves as a FIFO queue', () {
      final store = EventStore(storage: MemoryQueueStorage(), maxSize: 10);
      store
        ..add(event('a'))
        ..add(event('b'))
        ..add(event('c'));

      expect(store.length, 3);
      expect(actions(store.peek(2)), ['a', 'b']);
      expect(store.length, 3, reason: 'peek does not remove');

      store.removeFirst(2);
      expect(actions(store.peek(10)), ['c']);
    });

    test('add throws StateError at maxSize', () {
      final store = EventStore(storage: MemoryQueueStorage(), maxSize: 1)
        ..add(event('a'));
      expect(() => store.add(event('b')), throwsStateError);
    });

    test('persists and reloads events', () async {
      final storage = MemoryQueueStorage();
      final store = EventStore(storage: storage, maxSize: 10)
        ..add(event('a'))
        ..add(event('b'));
      await store.persist();

      final reloaded = EventStore(storage: storage, maxSize: 10);
      await reloaded.load();
      expect(actions(reloaded.peek(10)), ['a', 'b']);
    });

    test('writes the versioned file format', () async {
      final storage = MemoryQueueStorage();
      final store = EventStore(storage: storage, maxSize: 10)..add(event('a'));
      await store.persist();

      expect(storedActions(storage.contents), ['a']);
    });

    test('round-trips events with details', () async {
      final storage = MemoryQueueStorage();
      final original = MobyBeaconEvent(
        userId: 'user-1',
        category: 'test',
        action: 'a',
        timestamp: DateTime.utc(2026, 10, 7, 12, 30, 15, 250),
        details: {'s': 'text', 'i': 3, 'd': 1.5, 'b': true, 'n': null},
      );
      final store = EventStore(storage: storage, maxSize: 10)..add(original);
      await store.persist();

      final reloaded = EventStore(storage: storage, maxSize: 10);
      await reloaded.load();
      final loaded = reloaded.peek(1).single;
      expect(loaded.toJson(), original.toJson());
    });

    test('load with nothing stored starts empty', () async {
      final storage = MemoryQueueStorage();
      final store = EventStore(storage: storage, maxSize: 10);
      await store.load();
      expect(store.length, 0);
      expect(storage.quarantined, isFalse);
    });

    test('load quarantines an unparseable queue and starts empty', () async {
      final storage = MemoryQueueStorage('{not json');
      final messages = <String>[];
      final store = EventStore(
        storage: storage,
        maxSize: 10,
        onDiscarded: messages.add,
      );

      await store.load();
      expect(store.length, 0);
      expect(storage.quarantined, isTrue);
      expect(messages,
          ['Persisted event queue was unreadable and has been discarded']);
    });

    for (final contents in ['{}', '[]', '{"v":2,"events":[]}']) {
      test('load quarantines wrong-shape content $contents', () async {
        final storage = MemoryQueueStorage(contents);
        final messages = <String>[];
        final store = EventStore(storage: storage, maxSize: 10)
          ..onDiscarded = messages.add;

        await store.load();
        expect(store.length, 0);
        expect(storage.quarantined, isTrue);
        expect(messages, hasLength(1));
      });
    }

    test('load skips bad entries, keeps good ones, and rewrites the file',
        () async {
      final storage = MemoryQueueStorage(v1([
        event('a').toJson(),
        {'bogus': 1},
        event('b').toJson(),
      ]));
      final messages = <String>[];
      final store = EventStore(
        storage: storage,
        maxSize: 10,
        onDiscarded: messages.add,
      );

      await store.load();
      expect(actions(store.peek(10)), ['a', 'b']);
      expect(storage.quarantined, isFalse);
      expect(messages,
          ['1 persisted event(s) were unreadable and have been discarded']);

      await store.persist();
      expect(storedActions(storage.contents), ['a', 'b']);
    });

    test('load skips stored entries that fail validation', () async {
      final storage = MemoryQueueStorage(v1([
        event('a').toJson(),
        {
          ...event('nested').toJson(),
          'details': {
            'x': {'y': 1}
          }
        },
        {...event('blank').toJson(), 'category': ''},
        event('b').toJson(),
      ]));
      final messages = <String>[];
      final store = EventStore(
        storage: storage,
        maxSize: 10,
        onDiscarded: messages.add,
      );

      await store.load();
      expect(actions(store.peek(10)), ['a', 'b']);
      expect(messages,
          ['2 persisted event(s) were unreadable and have been discarded']);
    });

    test('load replaces lone surrogates in stored entries', () async {
      final storage = MemoryQueueStorage(v1([event('a\uD83D').toJson()]));
      final store = EventStore(storage: storage, maxSize: 10);

      await store.load();
      expect(actions(store.peek(10)), ['a\uFFFD']);
    });

    test('load keeps a stored queue larger than maxSize', () async {
      final storage = MemoryQueueStorage(v1([
        event('a').toJson(),
        event('b').toJson(),
        event('c').toJson(),
      ]));
      final store = EventStore(storage: storage, maxSize: 2);

      await store.load();
      expect(store.length, 3);
      expect(() => store.add(event('d')), throwsStateError);
    });

    test('load throws StateError when called twice', () async {
      final store = EventStore(storage: MemoryQueueStorage(), maxSize: 10);
      await store.load();
      await expectLater(store.load(), throwsStateError);
    });

    test('load throws StateError after a mutation', () async {
      final store = EventStore(storage: MemoryQueueStorage(), maxSize: 10)
        ..add(event('a'));
      await expectLater(store.load(), throwsStateError);
    });

    test('coalesces rapid mutations into at most two writes', () async {
      final storage = MemoryQueueStorage();
      final store = EventStore(storage: storage, maxSize: 1000);
      for (var i = 0; i < 100; i++) {
        store.add(event('e$i'));
      }
      await store.persist();

      expect(storage.writeCount, lessThanOrEqualTo(2));
      expect(storedActions(storage.contents), hasLength(100));
    });

    test('persist reflects removals', () async {
      final storage = MemoryQueueStorage();
      final store = EventStore(storage: storage, maxSize: 10)
        ..add(event('a'))
        ..add(event('b'))
        ..removeFirst(1);
      await store.persist();

      expect(storedActions(storage.contents), ['b']);
    });

    test('a mutation during a write causes exactly one follow-up write',
        () async {
      final gate = Completer<void>();
      final storage = MemoryQueueStorage()..writeGate = gate;
      final store = EventStore(storage: storage, maxSize: 10)..add(event('a'));
      await settle();
      expect(storage.writeCount, 1, reason: 'first write is in flight');

      store.add(event('b'));
      var persisted = false;
      final persisting = store.persist().then((_) => persisted = true);
      await settle();
      expect(persisted, isFalse);

      gate.complete();
      await persisting;
      expect(storage.writeCount, 2);
      expect(storedActions(storage.contents), ['a', 'b']);
    });

    test('persist retries a failed write', () async {
      final storage = MemoryQueueStorage()
        ..writeError = const FileSystemException('disk full');
      final store = EventStore(storage: storage, maxSize: 10)..add(event('a'));
      await store.persist();
      expect(storage.contents, isNull);

      storage.writeError = null;
      await store.persist();
      expect(storedActions(storage.contents), ['a']);
    });

    test('add rejects an event that cannot be encoded as JSON', () async {
      final storage = MemoryQueueStorage();
      final store = EventStore(storage: storage, maxSize: 10);
      final bad = MobyBeaconEvent(
        userId: 'user-1',
        category: 'test',
        action: 'bad',
        timestamp: DateTime.utc(2026, 10, 7),
        details: {'x': Object()},
      );

      expect(() => store.add(bad), throwsArgumentError);
      expect(store.length, 0);

      store.add(event('a'));
      await store.persist();
      expect(storage.writeCount, greaterThan(0));
      expect(storedActions(storage.contents), ['a']);
    });

    test('an unreadable store is not quarantined or overwritten', () async {
      final storage = MemoryQueueStorage(v1([event('stored').toJson()]))
        ..readError = const FileSystemException('locked');
      final messages = <String>[];
      final store = EventStore(
        storage: storage,
        maxSize: 10,
        onDiscarded: messages.add,
      );

      await store.load();
      expect(store.length, 0);
      expect(storage.quarantined, isFalse);

      store.add(event('new'));
      await store.persist();
      expect(storage.writeCount, 0);
      expect(storedActions(storage.contents), ['stored']);

      storage.readError = null;
      await store.persist();
      expect(actions(store.peek(10)), ['new', 'stored']);
      expect(storedActions(storage.contents), ['new', 'stored']);
      expect(messages, isEmpty);
    });
  });

  group('EventStore.peek with maxBytes', () {
    /// UTF-8 size of [e] as the store encodes it.
    int bytesOf(MobyBeaconEvent e) =>
        utf8.encode(jsonEncode(e.toJson())).length;

    test('returns the longest prefix whose entries and commas fit', () {
      final store = EventStore(storage: MemoryQueueStorage(), maxSize: 10)
        ..add(event('a'))
        ..add(event('b'))
        ..add(event('c'));
      final size = bytesOf(event('a'));

      expect(actions(store.peek(10, maxBytes: 2 * size + 1)), ['a', 'b']);
      expect(actions(store.peek(10, maxBytes: 2 * size)), ['a'],
          reason: 'the comma between entries counts');
      expect(actions(store.peek(10, maxBytes: 3 * size + 2)), ['a', 'b', 'c']);
    });

    test('still respects count', () {
      final store = EventStore(storage: MemoryQueueStorage(), maxSize: 10)
        ..add(event('a'))
        ..add(event('b'));

      expect(actions(store.peek(1, maxBytes: 1 << 20)), ['a']);
    });

    test('returns one event even when it exceeds maxBytes', () {
      final store = EventStore(storage: MemoryQueueStorage(), maxSize: 10)
        ..add(event('a'))
        ..add(event('b'));

      expect(actions(store.peek(10, maxBytes: 1)), ['a']);
    });

    test('returns nothing from an empty store', () {
      final store = EventStore(storage: MemoryQueueStorage(), maxSize: 10);

      expect(store.peek(10, maxBytes: 1), isEmpty);
    });

    test('measures UTF-8 bytes, not string length', () {
      final store = EventStore(storage: MemoryQueueStorage(), maxSize: 10)
        ..add(event('üüüü'))
        ..add(event('üüüü'));
      final chars = jsonEncode(event('üüüü').toJson()).length;

      expect(store.peek(10, maxBytes: 2 * chars + 1), hasLength(1));
      expect(store.peek(10, maxBytes: 2 * bytesOf(event('üüüü')) + 1),
          hasLength(2));
    });

    test('measures events loaded from storage', () async {
      final storage =
          MemoryQueueStorage(v1([event('a').toJson(), event('b').toJson()]));
      final store = EventStore(storage: storage, maxSize: 10);
      await store.load();
      final size = bytesOf(event('a'));

      expect(actions(store.peek(10, maxBytes: 2 * size)), ['a']);
      expect(actions(store.peek(10, maxBytes: 2 * size + 1)), ['a', 'b']);
    });
  });

  group('FileQueueStorage', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('moby_beacon_test');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    File file(String name) => File('${dir.path}/$name');

    test('read returns null when no file exists', () async {
      expect(await FileQueueStorage(dir).read(), isNull);
    });

    test('write then read round-trips and leaves no temp file', () async {
      final storage = FileQueueStorage(dir);
      await storage.write('[1,2,3]');

      expect(await storage.read(), '[1,2,3]');
      expect(file('queue.json.tmp').existsSync(), isFalse);
    });

    test('write creates a missing directory', () async {
      final nested = Directory('${dir.path}/nested/moby_beacon');
      await FileQueueStorage(nested).write('[]');
      expect(File('${nested.path}/queue.json').existsSync(), isTrue);
    });

    test('quarantine moves the queue aside', () async {
      final storage = FileQueueStorage(dir);
      await storage.write('{not json');
      await storage.quarantine();

      expect(await storage.read(), isNull);
      expect(file('queue.json.corrupt').readAsStringSync(), '{not json');
    });

    test('a stray temp file is ignored by read and replaced by write',
        () async {
      file('queue.json.tmp').writeAsStringSync('partial');
      final storage = FileQueueStorage(dir);
      expect(await storage.read(), isNull);

      await storage.write('complete');
      expect(await storage.read(), 'complete');
      expect(file('queue.json.tmp').existsSync(), isFalse);
    });

    test('a failed write removes its temp file and rethrows', () async {
      // A directory where queue.json should be makes the rename fail.
      Directory('${dir.path}/queue.json').createSync();
      final storage = FileQueueStorage(dir);

      await expectLater(storage.write('data'), throwsA(isA<Exception>()));
      expect(file('queue.json.tmp').existsSync(), isFalse);
    });

    test('invalid UTF-8 reads as text and is quarantined by load', () async {
      file('queue.json').writeAsBytesSync([0xff, 0xfe, 0x7b, 0x80]);
      final storage = FileQueueStorage(dir);
      expect(await storage.read(), isA<String>());

      final messages = <String>[];
      final store = EventStore(
        storage: storage,
        maxSize: 10,
        onDiscarded: messages.add,
      );
      await store.load();
      expect(store.length, 0);
      expect(messages, hasLength(1));
      expect(file('queue.json').existsSync(), isFalse);
      expect(file('queue.json.corrupt').existsSync(), isTrue);
    });

    test('EventStore survives a reload from disk', () async {
      final store = EventStore(storage: FileQueueStorage(dir), maxSize: 10)
        ..add(event('a'));
      await store.persist();

      final reloaded = EventStore(storage: FileQueueStorage(dir), maxSize: 10);
      await reloaded.load();
      expect(actions(reloaded.peek(10)), ['a']);
    });
  });
}
