import 'package:flutter_test/flutter_test.dart';
import 'package:moby_beacon/src/config.dart';

MobyBeaconConfig config({
  String endpoint = 'https://beacon.test',
  String apiKey = 'key-123',
  String userId = 'user-1',
  Duration flushInterval = const Duration(seconds: 5),
  int batchSize = 10,
  int maxQueueSize = 10000,
}) =>
    MobyBeaconConfig(
      endpoint: endpoint,
      apiKey: apiKey,
      userId: userId,
      flushInterval: flushInterval,
      batchSize: batchSize,
      maxQueueSize: maxQueueSize,
    );

void main() {
  test('applies defaults', () {
    final c = MobyBeaconConfig(
        endpoint: 'https://beacon.test', apiKey: 'k', userId: 'u');
    expect(c.flushInterval, const Duration(seconds: 5));
    expect(c.batchSize, 10);
    expect(c.maxQueueSize, 10000);
    expect(c.onError, isNull);
  });

  test('strips a trailing slash from endpoint', () {
    expect(config(endpoint: 'https://beacon.test/').endpoint,
        'https://beacon.test');
  });

  test('rejects empty endpoint, apiKey, and userId', () {
    expect(() => config(endpoint: ''), throwsArgumentError);
    expect(() => config(endpoint: '/'), throwsArgumentError);
    expect(() => config(apiKey: ''), throwsArgumentError);
    expect(() => config(userId: ''), throwsArgumentError);
  });

  test('rejects non-positive flushInterval, batchSize, and maxQueueSize', () {
    expect(() => config(flushInterval: Duration.zero), throwsArgumentError);
    expect(() => config(batchSize: 0), throwsArgumentError);
    expect(() => config(maxQueueSize: 0), throwsArgumentError);
  });

  test('strips all trailing slashes and keeps any path', () {
    expect(config(endpoint: 'https://beacon.test//').endpoint,
        'https://beacon.test');
    expect(config(endpoint: 'https://beacon.test/api/').endpoint,
        'https://beacon.test/api');
  });

  test('rejects endpoints that are not absolute http(s) URLs', () {
    for (final endpoint in [
      'beacon.test',
      'localhost:3011',
      'ftp://beacon.test',
      'https://',
    ]) {
      expect(() => config(endpoint: endpoint), throwsArgumentError,
          reason: endpoint);
    }
  });

  test('rejects whitespace-only apiKey and userId', () {
    expect(() => config(apiKey: '  '), throwsArgumentError);
    expect(() => config(userId: '\n'), throwsArgumentError);
  });

  test('rejects a userId the API would not accept', () {
    expect(() => config(userId: 'x' * 256), throwsArgumentError);
    expect(() => config(userId: 'a\u0000b'), throwsArgumentError);
    expect(config(userId: 'x' * 255).userId, hasLength(255));
  });
}
