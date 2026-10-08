import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moby_beacon/src/event.dart';
import 'package:moby_beacon/src/transport.dart';

final events = [
  MobyBeaconEvent(
    userId: 'user-1',
    category: 'screen',
    action: 'view',
    timestamp: DateTime.utc(2026, 10, 7),
  ),
];

Transport transportWith(MockClientHandler handler,
        {Duration timeout = const Duration(seconds: 30)}) =>
    Transport(
      endpoint: 'https://beacon.test',
      apiKey: 'key-123',
      client: MockClient(handler),
      timeout: timeout,
    );

http.Response json(Object body, int status, {Map<String, String>? headers}) =>
    http.Response(jsonEncode(body), status, headers: headers ?? const {});

Matcher transportError({int? statusCode, int? retryAfter}) =>
    isA<TransportError>()
        .having((e) => e.statusCode, 'statusCode', statusCode)
        .having((e) => e.retryAfter, 'retryAfter', retryAfter);

void main() {
  test('posts events to {endpoint}/events with headers and body', () async {
    late http.Request captured;
    final transport = transportWith((request) async {
      captured = request;
      return json({'accepted': 1, 'errors': <Object>[]}, 201);
    });

    await transport.send(events);

    expect(captured.method, 'POST');
    expect(captured.url.toString(), 'https://beacon.test/events');
    expect(captured.headers['X-API-Key'], 'key-123');
    expect(captured.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(captured.body), {
      'events': [events.single.toJson()],
    });
  });

  test('returns the response on 201', () async {
    final transport = transportWith(
        (_) async => json({'accepted': 1, 'errors': <Object>[]}, 201));
    final response = await transport.send(events);
    expect(response.accepted, 1);
    expect(response.errors, isEmpty);
  });

  for (final status in [207, 422]) {
    test('returns per-event errors on $status', () async {
      final transport = transportWith((_) async => json({
            'accepted': 0,
            'errors': [
              {'index': 0, 'message': 'category is required'},
            ],
          }, status));
      final response = await transport.send(events);
      expect(response.errors.single.index, 0);
      expect(response.errors.single.message, 'category is required');
    });
  }

  test('throws with status on 5xx', () {
    final transport = transportWith((_) async => http.Response('', 503));
    expect(transport.send(events), throwsA(transportError(statusCode: 503)));
  });

  test('throws with retryAfter on 429', () {
    final transport = transportWith(
        (_) async => http.Response('', 429, headers: {'retry-after': '12'}));
    expect(transport.send(events),
        throwsA(transportError(statusCode: 429, retryAfter: 12)));
  });

  test('reads named throttler Retry-After headers on 429', () {
    final transport = transportWith(
      (_) async => http.Response('', 429, headers: {
        'retry-after-ip-limit': '37',
        'retry-after-key-limit': '5',
      }),
    );
    expect(transport.send(events),
        throwsA(transportError(statusCode: 429, retryAfter: 37)));
  });

  test('429 without a usable Retry-After has no retryAfter', () {
    final transport = transportWith(
      (_) async => http.Response('', 429, headers: {'retry-after': 'soon'}),
    );
    expect(transport.send(events), throwsA(transportError(statusCode: 429)));
  });

  test('reports a redirect distinctly', () {
    final transport = transportWith((_) async => http.Response('', 301));
    expect(
      transport.send(events),
      throwsA(isA<TransportError>()
          .having((e) => e.statusCode, 'statusCode', 301)
          .having((e) => e.message, 'message', contains('redirect'))),
    );
  });

  test('throws with status on 413 so the caller can split the batch', () {
    final transport = transportWith((_) async => http.Response('', 413));
    expect(transport.send(events), throwsA(transportError(statusCode: 413)));
  });

  for (final status in [400, 401, 403]) {
    test('throws with status on $status', () {
      final transport = transportWith((_) async => http.Response('', status));
      expect(
          transport.send(events), throwsA(transportError(statusCode: status)));
    });
  }

  test('throws without status when the client throws', () {
    final transport = transportWith(
        (_) async => throw http.ClientException('connection refused'));
    expect(transport.send(events), throwsA(transportError()));
  });

  test('throws without status on timeout', () {
    final never = Completer<http.Response>();
    final transport = transportWith((_) => never.future,
        timeout: const Duration(milliseconds: 10));
    expect(transport.send(events), throwsA(transportError()));
  });
}
