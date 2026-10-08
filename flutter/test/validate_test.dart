import 'package:flutter_test/flutter_test.dart';
import 'package:moby_beacon/src/event.dart';
import 'package:moby_beacon/src/validate.dart';

MobyBeaconEvent event({
  String userId = 'user-1',
  String category = 'screen',
  String action = 'view',
  Map<String, Object?>? details,
}) =>
    MobyBeaconEvent(
      userId: userId,
      category: category,
      action: action,
      timestamp: DateTime.utc(2026, 10, 7),
      details: details,
    );

Matcher throwsMessage(String message) =>
    throwsA(isA<ArgumentError>().having((e) => e.message, 'message', message));

void main() {
  test('accepts a minimal event', () {
    expect(() => validateEvent(event()), returnsNormally);
  });

  test('accepts primitive details', () {
    expect(
      () => validateEvent(event(details: {
        's': 'text',
        'i': 3,
        'd': 1.5,
        'b': true,
        'n': null,
      })),
      returnsNormally,
    );
  });

  for (final field in ['userId', 'category', 'action']) {
    MobyBeaconEvent withField(String value) => event(
          userId: field == 'userId' ? value : 'user-1',
          category: field == 'category' ? value : 'screen',
          action: field == 'action' ? value : 'view',
        );

    test('rejects empty $field', () {
      expect(() => validateEvent(withField('')),
          throwsMessage('$field is required and must be a non-empty string'));
    });

    test('rejects $field over 255 characters', () {
      expect(() => validateEvent(withField('x' * 256)),
          throwsMessage('$field must be at most 255 characters'));
    });
  }

  test('rejects nested map values', () {
    expect(
      () => validateEvent(event(details: {
        'nested': {'a': 1},
      })),
      throwsMessage('details.nested must be a string, number, boolean, or '
          'null — not a nested object or array'),
    );
  });

  test('rejects list values', () {
    expect(
      () => validateEvent(event(details: {
        'list': [1, 2],
      })),
      throwsMessage('details.list must be a string, number, boolean, or '
          'null — not a nested object or array'),
    );
  });

  test('rejects more than 50 keys', () {
    final details = {for (var i = 0; i < 51; i++) 'k$i': i};
    expect(() => validateEvent(event(details: details)),
        throwsMessage('details must have at most 50 keys'));
  });

  test('rejects keys over 255 characters', () {
    expect(() => validateEvent(event(details: {'k' * 256: 1})),
        throwsMessage('details key must be at most 255 characters'));
  });

  test('rejects string values over 1000 characters', () {
    expect(() => validateEvent(event(details: {'s': 'x' * 1001})),
        throwsMessage('details string values must be at most 1000 characters'));
  });

  test('rejects NaN and infinity', () {
    expect(() => validateEvent(event(details: {'n': double.nan})),
        throwsMessage('details.n must be a finite number'));
    expect(() => validateEvent(event(details: {'n': double.infinity})),
        throwsMessage('details.n must be a finite number'));
  });

  test('rejects NUL characters in required strings', () {
    expect(() => validateEvent(event(category: 'a\u0000b')),
        throwsMessage('category must not contain NUL characters'));
  });

  test('rejects NUL characters in details keys and string values', () {
    expect(() => validateEvent(event(details: {'k\u0000': 1})),
        throwsMessage('details keys must not contain NUL characters'));
    expect(() => validateEvent(event(details: {'s': 'a\u0000'})),
        throwsMessage('details.s must not contain NUL characters'));
  });

  test('accepts values exactly at the limits', () {
    expect(
      () => validateEvent(event(
        category: 'x' * 255,
        details: {
          for (var i = 0; i < 49; i++) 'k$i': i,
          'k' * 255: 'x' * 1000,
        },
      )),
      returnsNormally,
    );
  });

  test('rejects a whitespace-only userId', () {
    expect(() => validateEvent(event(userId: ' \t\n')),
        throwsMessage('userId must not be blank'));
  });

  group('sanitizeString', () {
    test('replaces a lone high surrogate', () {
      expect(sanitizeString('a\uD83Db'), 'a\uFFFDb');
    });

    test('replaces a lone low surrogate', () {
      expect(sanitizeString('a\uDE00b'), 'a\uFFFDb');
    });

    test('replaces a high surrogate at the end of the string', () {
      expect(
          sanitizeString('I feel \u{1F600}'.substring(0, 8)), 'I feel \uFFFD');
    });

    test('replaces each half of a reversed pair', () {
      expect(sanitizeString('\uDE00\uD83D'), '\uFFFD\uFFFD');
    });

    test('keeps valid pairs and other text unchanged', () {
      const text = 'plain, accents é, emoji \u{1F600}\u{1F44D}';
      expect(sanitizeString(text), same(text));
      expect(sanitizeString(''), '');
    });
  });

  group('sanitizeEvent', () {
    test('cleans required strings, details keys and string values', () {
      final cleaned = sanitizeEvent(MobyBeaconEvent(
        userId: 'u\uD83D',
        category: 'c\uDE00',
        action: '\uD83Da',
        timestamp: DateTime.utc(2026, 10, 7),
        details: {'k\uD83D': 'v\uDE00', 'n': 1, 'b': true, 'z': null},
      ));

      expect(cleaned.userId, 'u\uFFFD');
      expect(cleaned.category, 'c\uFFFD');
      expect(cleaned.action, '\uFFFDa');
      expect(cleaned.timestamp, DateTime.utc(2026, 10, 7));
      expect(cleaned.details,
          {'k\uFFFD': 'v\uFFFD', 'n': 1, 'b': true, 'z': null});
    });

    test('copies details into an unmodifiable map', () {
      final details = <String, Object?>{'a': 1};
      final cleaned = sanitizeEvent(event(details: details));
      details['a'] = 2;

      expect(cleaned.details, {'a': 1});
      expect(() => cleaned.details!['b'] = 1, throwsUnsupportedError);
    });

    test('keeps null details', () {
      expect(sanitizeEvent(event()).details, isNull);
    });
  });
}
