import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:moby_beacon/moby_beacon.dart';

const _apiKey = String.fromEnvironment('BEACON_API_KEY');
const _endpoint = String.fromEnvironment('BEACON_ENDPOINT');

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

  // One instance for the app's lifetime; it is never disposed.
  final beacon = await MobyBeacon.create(MobyBeaconConfig(
    endpoint: _endpoint.isEmpty ? _defaultEndpoint : _endpoint,
    apiKey: _apiKey,
    userId: 'example-participant',
    onError: (error) => debugPrint('$error'),
  ));

  runApp(ExampleApp(beacon: beacon));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, required this.beacon});

  final MobyBeacon beacon;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Moby Beacon example')),
        body: Builder(
          builder: (context) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: () {
                    beacon.track('button', 'tap',
                        details: {'id': 'example-button'});
                    _show(context, 'Tracked button/tap');
                  },
                  child: const Text('Track a tap'),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () async {
                    await beacon.flush();
                    if (context.mounted) _show(context, 'Flush finished');
                  },
                  child: const Text('Flush now'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _show(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
