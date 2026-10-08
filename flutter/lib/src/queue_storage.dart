import 'dart:convert';
import 'dart:io';

/// Where the serialized event queue is kept between app runs.
abstract interface class QueueStorage {
  /// Returns the stored queue, or null if nothing has been stored. Throws if
  /// storage is temporarily unavailable (e.g. iOS before first unlock).
  Future<String?> read();

  /// Replaces the stored queue with [contents].
  Future<void> write(String contents);

  /// Moves an unreadable stored queue aside so it is not loaded again.
  Future<void> quarantine();
}

/// Stores the queue as `queue.json` in [directory], writing atomically via a
/// temp file and rename.
class FileQueueStorage implements QueueStorage {
  FileQueueStorage(this.directory);

  final Directory directory;

  File get _file => File('${directory.path}/queue.json');
  File get _tempFile => File('${directory.path}/queue.json.tmp');
  File get _corruptFile => File('${directory.path}/queue.json.corrupt');

  @override
  Future<String?> read() async {
    final List<int> bytes;
    try {
      bytes = await _file.readAsBytes();
    } on PathNotFoundException {
      return null;
    }
    // Malformed bytes become U+FFFD rather than throwing here (which would
    // mean "unavailable, try again later"). Damage inside a JSON string just
    // alters that string; only structural damage fails parsing and is treated
    // as corruption.
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<void> write(String contents) async {
    try {
      await directory.create(recursive: true);
      await _tempFile.writeAsString(contents, flush: true);
      await _tempFile.rename(_file.path);
    } catch (_) {
      try {
        await _tempFile.delete();
      } catch (_) {
        // Best effort; the next write replaces it anyway.
      }
      rethrow;
    }
  }

  @override
  Future<void> quarantine() async {
    if (await _file.exists()) {
      await _file.rename(_corruptFile.path);
    }
  }
}
