import 'dart:convert';
import 'dart:math';

import 'event.dart';
import 'queue_storage.dart';
import 'validate.dart';

/// An event together with its JSON, encoded once so writes never re-encode
/// the whole queue, and that JSON's UTF-8 size for byte-bounded batches.
typedef _Entry = ({MobyBeaconEvent event, String json, int bytes});

_Entry _entry(MobyBeaconEvent event, String json) =>
    (event: event, json: json, bytes: utf8.encode(json).length);

/// FIFO queue of events, mirrored to [QueueStorage] so it survives restarts.
///
/// Mutations apply to memory immediately and schedule a write. At most one
/// write runs at a time; changes made during a write are picked up by a
/// single follow-up write.
///
/// The stored file is `{"v":1,"events":[...]}`.
class EventStore {
  EventStore({
    required QueueStorage storage,
    required this.maxSize,
    this.onDiscarded,
  }) : _storage = storage;

  static const _version = 1;

  final QueueStorage _storage;
  final int maxSize;

  /// Called with a human-readable message when stored events could not be
  /// read and were dropped. Settable so the owner can wire it after creation.
  void Function(String message)? onDiscarded;

  final List<_Entry> _entries = [];
  Future<void>? _writing;
  Future<void>? _reading;

  /// A mutation has not been written yet.
  bool _dirty = false;

  /// The last write failed, so disk may not match memory.
  bool _stale = false;

  /// The stored queue has not been read yet. Writing now would overwrite a
  /// backlog we have not seen, so writes wait until a read succeeds.
  bool _unread = false;

  bool _loadCalled = false;
  bool _mutated = false;

  int get length => _entries.length;

  /// Loads persisted events. Call once, before any mutation.
  ///
  /// Never throws for storage or content problems: unparseable content is
  /// quarantined and reported via [onDiscarded]; unavailable storage is
  /// retried before each later write.
  Future<void> load() async {
    if (_loadCalled || _mutated) {
      throw StateError('load() must be called once, before any mutation');
    }
    _loadCalled = true;
    _unread = true;
    await _ensureRead();
  }

  /// Appends [event]. Throws [StateError] when the queue holds [maxSize], or
  /// [ArgumentError] if the event cannot be encoded as JSON.
  void add(MobyBeaconEvent event) {
    if (_entries.length >= maxSize) {
      throw StateError('Queue is at capacity');
    }
    final String json;
    try {
      json = jsonEncode(event.toJson());
    } on JsonUnsupportedObjectError {
      throw ArgumentError('Event could not be encoded as JSON');
    }
    _mutated = true;
    _entries.add(_entry(event, json));
    _scheduleWrite();
  }

  /// Returns up to [count] events from the front without removing them.
  ///
  /// With [maxBytes], returns the longest such prefix whose UTF-8 encoded
  /// events, plus one comma between each, fit in [maxBytes]. At least one
  /// event is returned whenever the queue is non-empty, even if it alone is
  /// larger, so the caller can still send (or drop) it.
  List<MobyBeaconEvent> peek(int count, {int? maxBytes}) {
    var n = min(count, _entries.length);
    if (maxBytes != null && n > 1) {
      var total = _entries[0].bytes;
      var fits = 1;
      while (fits < n) {
        total += 1 + _entries[fits].bytes;
        if (total > maxBytes) break;
        fits++;
      }
      n = fits;
    }
    return List.unmodifiable(_entries.take(n).map((entry) => entry.event));
  }

  /// Removes up to [count] events from the front.
  void removeFirst(int count) {
    _mutated = true;
    final n = min(count, _entries.length);
    if (n == 0) return;
    _entries.removeRange(0, n);
    _scheduleWrite();
  }

  /// Waits for any in-flight write, then makes one more attempt if disk may
  /// still differ from memory. Never throws.
  Future<void> persist() async {
    final inFlight = _writing;
    if (inFlight != null) await inFlight;
    if (_dirty || _stale || _unread) {
      _dirty = true;
      await (_writing ??= _drainWrites());
    }
  }

  void _scheduleWrite() {
    _dirty = true;
    _writing ??= _drainWrites();
  }

  Future<void> _drainWrites() async {
    // Yield first so `_writing` is assigned before this can complete.
    await null;
    try {
      while (_dirty) {
        if (_unread) {
          await _ensureRead();
          // Still unavailable: leave _dirty set so a later attempt retries.
          if (_unread) return;
        }
        _dirty = false;
        try {
          await _storage.write(_encode());
          _stale = false;
        } catch (_) {
          // Keep working from memory; persist() or the next mutation retries.
          _stale = true;
        }
      }
    } finally {
      _writing = null;
    }
  }

  String _encode() =>
      '{"v":$_version,"events":[${_entries.map((e) => e.json).join(',')}]}';

  Future<void> _ensureRead() => _reading ??= _readStored();

  Future<void> _readStored() async {
    // Yield first so `_reading` is assigned before this can complete.
    await null;
    try {
      final String? contents;
      try {
        contents = await _storage.read();
      } catch (_) {
        return; // Unavailable (e.g. iOS before first unlock); retry later.
      }
      if (contents == null) {
        _unread = false;
        return;
      }
      final parsed = _parse(contents);
      if (parsed == null) {
        try {
          await _storage.quarantine();
        } catch (_) {
          // Nothing more we can do; start empty either way.
        }
        _unread = false;
        _report('Persisted event queue was unreadable and has been discarded');
        return;
      }
      _unread = false;
      final (entries, skipped) = parsed;
      // Append, never prepend: a flush may have peeked the front of the
      // queue and will remove exactly that many events when it finishes.
      _entries.addAll(entries);
      if (skipped > 0) {
        _report('$skipped persisted event(s) were unreadable and have been '
            'discarded');
        _scheduleWrite(); // Drop the bad entries from disk.
      }
    } finally {
      _reading = null;
    }
  }

  /// Returns the stored entries and how many were skipped, or null if the
  /// content as a whole is unreadable.
  static (List<_Entry>, int)? _parse(String contents) {
    final Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?> ||
        decoded['v'] != _version ||
        decoded['events'] is! List<Object?>) {
      return null;
    }
    final entries = <_Entry>[];
    var skipped = 0;
    for (final json in decoded['events']! as List<Object?>) {
      try {
        final event = sanitizeEvent(
            MobyBeaconEvent.fromJson(json! as Map<String, Object?>));
        validateEvent(event);
        entries.add(_entry(event, jsonEncode(event.toJson())));
      } catch (_) {
        skipped++;
      }
    }
    return (entries, skipped);
  }

  void _report(String message) {
    try {
      onDiscarded?.call(message);
    } catch (_) {
      // A throwing callback must not break loading or writing.
    }
  }
}
