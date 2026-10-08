import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:moby_beacon/moby_beacon.dart';

const _apiKey = String.fromEnvironment('BEACON_API_KEY');
const _endpoint = String.fromEnvironment('BEACON_ENDPOINT');
const _userId = 'example-participant';

/// The local API (port 3011) as seen from the Android emulator or the iOS
/// simulator. Plain HTTP needs platform opt-ins; see the package README.
String get _defaultEndpoint => defaultTargetPlatform == TargetPlatform.android
    ? 'http://10.0.2.2:3011'
    : 'http://localhost:3011';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_apiKey.isEmpty) {
    runApp(const _MissingKeyApp());
    return;
  }

  final log = ActivityLog();
  final endpoint = _endpoint.isEmpty ? _defaultEndpoint : _endpoint;
  log.add('Endpoint: $endpoint${_endpoint.isEmpty ? ' (default)' : ''}');
  final keyHint = _apiKey.length > 8
      ? '…${_apiKey.substring(_apiKey.length - 4)}'
      : '(${_apiKey.length} chars)';
  log.add('API key: $keyHint, user: $_userId');

  final MobyBeacon beacon;
  try {
    // One instance for the app's lifetime; it is never disposed.
    beacon = await MobyBeacon.create(MobyBeaconConfig(
      endpoint: endpoint,
      apiKey: _apiKey,
      userId: _userId,
      onError: log.addError,
    ));
  } catch (error) {
    log.add('Could not start: $error', isError: true);
    runApp(ExampleApp(log: log));
    return;
  }
  log.add('Started. Events are sent every 5 s or once 10 are queued; '
      'only failures are reported.');

  runApp(ExampleApp(log: log, beacon: beacon));
}

/// Recent SDK activity, shown on screen and printed to the console.
class ActivityLog extends ChangeNotifier {
  static const _maxEntries = 200;

  /// Newest first.
  final List<LogEntry> entries = [];

  /// Errors reported so far, so a flush can tell whether it hit any.
  int errorCount = 0;

  void add(String message, {bool isError = false}) {
    final entry = LogEntry(DateTime.now(), message, isError: isError);
    debugPrint('[moby_beacon_example] $entry');
    entries.insert(0, entry);
    if (entries.length > _maxEntries) entries.removeLast();
    if (isError) errorCount++;
    notifyListeners();
  }

  void addError(MobyBeaconError error) {
    final outcome = error.willRetry ? 'will retry' : 'dropped';
    final buffer = StringBuffer('${error.type.name}: ${error.message} '
        '(${error.events.length} event(s), $outcome)');
    for (final rejected in error.errors ?? const <EventBatchError>[]) {
      final event = error.events[rejected.index];
      buffer.write('\n  #${rejected.index} ${event.category}/${event.action}: '
          '${rejected.message}');
    }
    add(buffer.toString(), isError: true);
  }
}

class LogEntry {
  const LogEntry(this.time, this.message, {this.isError = false});

  final DateTime time;
  final String message;
  final bool isError;

  @override
  String toString() => '${time.toIso8601String().substring(11, 19)} '
      '${isError ? 'ERROR ' : ''}$message';
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, required this.log, this.beacon});

  final ActivityLog log;

  /// Null when the SDK failed to start; the log says why.
  final MobyBeacon? beacon;

  @override
  Widget build(BuildContext context) {
    final beacon = this.beacon;
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Moby Beacon example')),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton(
                      onPressed: beacon == null
                          ? null
                          : () {
                              beacon.track('button', 'tap',
                                  details: {'id': 'example-button'});
                              log.add('Tracked button/tap');
                            },
                      child: const Text('Track a tap'),
                    ),
                    OutlinedButton(
                      onPressed: beacon == null ? null : () => _flush(beacon),
                      child: const Text('Flush now'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _LogView(log: log)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _flush(MobyBeacon beacon) async {
    log.add('Flushing…');
    final errorsBefore = log.errorCount;
    await beacon.flush();
    log.add(
        log.errorCount == errorsBefore
            ? 'Flush finished: queue sent'
            : 'Flush finished with errors; events stay queued if retryable',
        isError: log.errorCount != errorsBefore);
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.log});

  final ActivityLog log;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) => ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: log.entries.length,
        itemBuilder: (context, index) {
          final entry = log.entries[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '$entry',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: entry.isError ? theme.colorScheme.error : null,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MissingKeyApp extends StatelessWidget {
  const _MissingKeyApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Run with --dart-define=BEACON_API_KEY=<ingest key> '
              '(and optionally --dart-define=BEACON_ENDPOINT=<url>).',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
