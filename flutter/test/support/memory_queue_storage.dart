import 'dart:async';

import 'package:moby_beacon/src/queue_storage.dart';

/// In-memory [QueueStorage] for tests. Completes via microtasks only, so it
/// works inside `fakeAsync`.
class MemoryQueueStorage implements QueueStorage {
  MemoryQueueStorage([this.contents]);

  String? contents;

  /// Number of write attempts, including ones that failed.
  int writeCount = 0;
  bool quarantined = false;

  /// When set, [read] throws it (simulates storage that is unavailable).
  Object? readError;

  /// When set, [write] throws it after [writeGate] opens.
  Object? writeError;

  /// When set, [write] waits for it before storing, holding the write in
  /// flight.
  Completer<void>? writeGate;

  @override
  Future<String?> read() async {
    final error = readError;
    if (error != null) throw error;
    return contents;
  }

  @override
  Future<void> write(String contents) async {
    writeCount++;
    final gate = writeGate;
    if (gate != null) await gate.future;
    final error = writeError;
    if (error != null) throw error;
    this.contents = contents;
  }

  @override
  Future<void> quarantine() async {
    quarantined = true;
    contents = null;
  }
}
