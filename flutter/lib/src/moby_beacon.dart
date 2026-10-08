import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'backoff.dart';
import 'config.dart';
import 'errors.dart';
import 'event.dart';
import 'event_store.dart';
import 'queue_storage.dart';
import 'transport.dart';
import 'validate.dart';

/// The API accepts at most this many events per request.
const maxEventsPerRequest = 1000;

/// Upper bound on the encoded events in one request. The API rejects JSON
/// bodies over 100 kB (Express's default), so this leaves headroom.
const maxRequestBytes = 64 * 1024;

/// Batches study events, persists them to disk, and sends them to a Moby
/// Beacon API. Create one instance per app with [MobyBeacon.create].
class MobyBeacon {
  MobyBeacon._({
    required MobyBeaconConfig config,
    required EventStore store,
    required Transport transport,
    DateTime Function()? clock,
    Random? random,
  })  : _config = config,
        _store = store,
        _transport = transport,
        _clock = clock ?? DateTime.now,
        _random = random ?? Random();

  final MobyBeaconConfig _config;
  final EventStore _store;
  final Transport _transport;
  final DateTime Function() _clock;
  final Random _random;

  Timer? _timer;
  Future<void>? _inFlight;
  bool _flushRequested = false;
  int _consecutiveFailures = 0;
  bool _disposing = false;
  Future<void>? _disposeFuture;
  late final _observer = _LifecycleObserver(_handleLifecycle);

  /// Most events sent in one request. Lowered when the server answers 413.
  int _batchLimit = maxEventsPerRequest;

  /// The instance that has been created and whose [dispose] has not yet
  /// completed. Two instances would share, and overwrite, one queue file.
  static MobyBeacon? _live;

  /// Loads any events left from a previous run, then starts sending.
  ///
  /// Call `WidgetsFlutterBinding.ensureInitialized()` first if this runs
  /// before `runApp`. Throws if the platform's application support directory
  /// is unavailable, and throws [StateError] if another instance is still
  /// running (create one per app, or await [dispose] before replacing it).
  static Future<MobyBeacon> create(MobyBeaconConfig config) async {
    _checkNoLiveInstance();
    final supportDir = await getApplicationSupportDirectory();
    return createWith(
      config: config,
      store: EventStore(
        storage: FileQueueStorage(Directory('${supportDir.path}/moby_beacon')),
        maxSize: config.maxQueueSize,
      ),
      transport: Transport(endpoint: config.endpoint, apiKey: config.apiKey),
    );
  }

  /// Forgets the live instance, for tests whose dispose cannot complete.
  @visibleForTesting
  static void resetLiveInstanceForTesting() => _live = null;

  static void _checkNoLiveInstance() {
    if (_live != null) {
      throw StateError('A MobyBeacon is already running. Use one instance per '
          'app, or await dispose() on it before creating another.');
    }
  }

  @visibleForTesting
  static Future<MobyBeacon> createWith({
    required MobyBeaconConfig config,
    required EventStore store,
    required Transport transport,
    DateTime Function()? clock,
    Random? random,
  }) async {
    _checkNoLiveInstance();
    final beacon = _live = MobyBeacon._(
      config: config,
      store: store,
      transport: transport,
      clock: clock,
      random: random,
    );
    try {
      await beacon._start();
    } catch (_) {
      _live = null;
      rethrow;
    }
    return beacon;
  }

  Future<void> _start() async {
    _store.onDiscarded =
        (message) => _report(MobyBeaconErrorType.validation, message, const []);
    await _store.load();
    WidgetsBinding.instance.addObserver(_observer);
    _scheduleTimer();
    if (_store.length > 0) unawaited(flush());
  }

  /// Queues an event. Never throws; invalid events and a full queue are
  /// reported through `onError`.
  void track(
    String category,
    String action, {
    Map<String, Object?>? details,
    String? userId,
    DateTime? timestamp,
  }) {
    if (_disposing) return;

    // sanitizeEvent also copies details, so later changes by the caller
    // cannot alter the queued event.
    final event = sanitizeEvent(MobyBeaconEvent(
      userId: userId ?? _config.userId,
      category: category,
      action: action,
      timestamp: (timestamp ?? _clock()).toUtc(),
      details: details,
    ));

    try {
      validateEvent(event);
      _store.add(event);
    } on ArgumentError catch (error) {
      _report(MobyBeaconErrorType.validation, '${error.message}', [event]);
      return;
    } on StateError catch (error) {
      _report(MobyBeaconErrorType.validation, error.message, [event]);
      return;
    }

    // While backing off, leave retries to the timer so tracking cannot
    // bypass the backoff or a server's Retry-After.
    if (_store.length >= _config.batchSize && _consecutiveFailures == 0) {
      scheduleMicrotask(() => unawaited(flush()));
    }
  }

  /// Sends queued events. Completes when the queue is empty or a send fails
  /// transiently (events stay queued and are retried with backoff).
  ///
  /// If a flush is already running, this waits for it and for the follow-up
  /// run that sends events queued meanwhile. Does nothing once [dispose] has
  /// been called.
  Future<void> flush() {
    if (_disposing) return Future<void>.value();
    return _requestFlush();
  }

  Future<void> _requestFlush() {
    final inFlight = _inFlight;
    if (inFlight != null) {
      _flushRequested = true;
      // A follow-up run is assigned to `_inFlight` in `_runFlush`'s finally,
      // before `inFlight` completes, so this waits for it too.
      return inFlight.then((_) => _inFlight ?? Future<void>.value());
    }
    return _inFlight = _runFlush();
  }

  /// Stops automatic flushing and sends what it can. Unsent events stay on
  /// disk for the next instance. After this is called, [track] and [flush]
  /// do nothing. Calling it again returns the same future.
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposing = true;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(_observer);
    await _idle();
    await _requestFlush();
    await _idle();
    await _store.persist();
    await _idle();
    _transport.close();
    if (identical(_live, this)) _live = null;
  }

  void _handleLifecycle(AppLifecycleState state) {
    if (_disposing) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(_store.persist());
        unawaited(flush());
      case AppLifecycleState.resumed:
        _consecutiveFailures = 0;
        // persist() first: if storage was locked at launch (iOS before first
        // unlock), it retries reading the stored backlog so it gets sent too.
        unawaited(_store.persist().then((_) => flush()));
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Waits until no flush is running.
  Future<void> _idle() async {
    for (var inFlight = _inFlight; inFlight != null; inFlight = _inFlight) {
      await inFlight;
    }
  }

  Future<void> _runFlush() async {
    // Yield first so `_inFlight` is assigned before the `finally` below
    // clears it; with an empty queue nothing else would suspend.
    await null;
    int? retryAfter;
    try {
      while (_store.length > 0) {
        final batch = _store.peek(_batchLimit, maxBytes: maxRequestBytes);
        try {
          final response = await _transport.send(batch);
          _store.removeFirst(batch.length);
          _consecutiveFailures = 0;
          if (response.errors.isNotEmpty) {
            _report(
              MobyBeaconErrorType.validation,
              '${response.errors.length} event(s) rejected by server',
              batch,
              errors: response.errors,
            );
          }
        } on TransportError catch (error) {
          final status = error.statusCode;
          if (status == null) {
            _consecutiveFailures++;
            _report(MobyBeaconErrorType.network, error.message, batch,
                willRetry: true);
            break;
          }
          if (status == 408 || status == 429 || status >= 500) {
            _consecutiveFailures++;
            retryAfter = error.retryAfter;
            _report(MobyBeaconErrorType.server, error.message, batch,
                willRetry: true);
            break;
          }
          if (status == 413) {
            // The server answered, so the connection is healthy again.
            _consecutiveFailures = 0;
            if (batch.length > 1) {
              // Too large for the server: retry right away in smaller
              // requests. Not a failure; nothing is reported.
              _batchLimit = max(1, batch.length ~/ 2);
              continue;
            }
            _store.removeFirst(1);
            // Only that one event was too large; send the rest in full
            // batches again.
            _batchLimit = maxEventsPerRequest;
            _report(MobyBeaconErrorType.validation,
                'Event is larger than the API accepts', batch);
            continue;
          }
          // Anything else (401/403, 404, 3xx, other 4xx, unexpected 2xx) is
          // likely a configuration or deployment problem that will be fixed
          // without an app update. Keep the events and retry rarely.
          _consecutiveFailures++;
          retryAfter = maxFlushDelay.inSeconds;
          _report(
            status == 401 || status == 403
                ? MobyBeaconErrorType.auth
                : MobyBeaconErrorType.server,
            error.message,
            batch,
            willRetry: true,
          );
          break;
        } catch (error) {
          // Not expected from the transport; keep the events and back off
          // rather than let it escape as an unhandled async error.
          _consecutiveFailures++;
          _report(
              MobyBeaconErrorType.network, 'Unexpected error: $error', batch,
              willRetry: true);
          break;
        }
      }
    } finally {
      _inFlight = null;
      if (_store.length == 0) _batchLimit = maxEventsPerRequest;
      final runAgain = _flushRequested && _consecutiveFailures == 0;
      _flushRequested = false;
      if (!_disposing) {
        _scheduleTimer(retryAfter);
        if (runAgain) unawaited(_requestFlush());
      }
    }
  }

  void _scheduleTimer([int? retryAfterSeconds]) {
    _timer?.cancel();
    _timer = Timer(
      nextFlushDelay(
        baseInterval: _config.flushInterval,
        consecutiveFailures: _consecutiveFailures,
        retryAfterSeconds: retryAfterSeconds,
        random: _random,
      ),
      () => unawaited(flush()),
    );
  }

  void _report(
    MobyBeaconErrorType type,
    String message,
    List<MobyBeaconEvent> events, {
    List<EventBatchError>? errors,
    bool willRetry = false,
  }) {
    final onError = _config.onError;
    if (onError == null) return;
    try {
      onError(MobyBeaconError(
        type: type,
        message: message,
        events: events,
        errors: errors,
        willRetry: willRetry,
      ));
    } catch (_) {
      // A failing error handler must not break event delivery.
    }
  }
}

/// Forwards app lifecycle changes without exposing [WidgetsBindingObserver]
/// on the public class.
class _LifecycleObserver with WidgetsBindingObserver {
  _LifecycleObserver(this._onChange);

  final void Function(AppLifecycleState state) _onChange;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _onChange(state);
}
