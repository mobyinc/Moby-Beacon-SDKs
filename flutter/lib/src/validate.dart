import 'event.dart';

/// Longest `userId`, `category`, `action` or details key the API accepts.
const maxFieldLength = 255;
const _maxStringLength = maxFieldLength;
const _maxDetailKeys = 50;
const _maxDetailStringLength = 1000;

/// Checks [event] against the API's ingest rules. Throws [ArgumentError] with
/// a descriptive message on the first violation.
void validateEvent(MobyBeaconEvent event) {
  _validateRequiredString(event.userId, 'userId');
  _validateRequiredString(event.category, 'category');
  _validateRequiredString(event.action, 'action');

  final details = event.details;
  if (details == null) return;

  if (details.length > _maxDetailKeys) {
    throw ArgumentError('details must have at most $_maxDetailKeys keys');
  }
  for (final MapEntry(:key, :value) in details.entries) {
    if (key.length > _maxStringLength) {
      throw ArgumentError(
          'details key must be at most $_maxStringLength characters');
    }
    if (key.contains('\u0000')) {
      throw ArgumentError('details keys must not contain NUL characters');
    }
    if (value == null || value is bool) continue;
    if (value is String) {
      if (value.length > _maxDetailStringLength) {
        throw ArgumentError('details string values must be at most '
            '$_maxDetailStringLength characters');
      }
      if (value.contains('\u0000')) {
        throw ArgumentError('details.$key must not contain NUL characters');
      }
      continue;
    }
    if (value is num) {
      if (!value.isFinite) {
        throw ArgumentError('details.$key must be a finite number');
      }
      continue;
    }
    throw ArgumentError('details.$key must be a string, number, boolean, or '
        'null — not a nested object or array');
  }
}

void _validateRequiredString(String value, String field) {
  if (value.isEmpty) {
    throw ArgumentError('$field is required and must be a non-empty string');
  }
  if (field == 'userId' && value.trim().isEmpty) {
    throw ArgumentError('userId must not be blank');
  }
  if (value.length > _maxStringLength) {
    throw ArgumentError('$field must be at most $_maxStringLength characters');
  }
  if (value.contains('\u0000')) {
    throw ArgumentError('$field must not contain NUL characters');
  }
}

/// Returns [event] with every unpaired UTF-16 surrogate in its strings
/// (`userId`, `category`, `action`, details keys and string values) replaced
/// by U+FFFD, and its details copied into an unmodifiable map.
///
/// Truncating text in the middle of an emoji leaves a lone surrogate.
/// `jsonEncode` writes it as an escape that PostgreSQL rejects, which would
/// fail the whole batch on every retry.
MobyBeaconEvent sanitizeEvent(MobyBeaconEvent event) {
  final details = event.details;
  return MobyBeaconEvent(
    userId: sanitizeString(event.userId),
    category: sanitizeString(event.category),
    action: sanitizeString(event.action),
    timestamp: event.timestamp,
    details: details == null
        ? null
        : Map<String, Object?>.unmodifiable({
            for (final MapEntry(:key, :value) in details.entries)
              sanitizeString(key):
                  value is String ? sanitizeString(value) : value,
          }),
  );
}

/// Replaces unpaired UTF-16 surrogates in [value] with U+FFFD. Returns
/// [value] itself when there are none.
String sanitizeString(String value) {
  List<int>? units;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit < 0xD800 || unit > 0xDFFF) continue;
    if (unit <= 0xDBFF && i + 1 < value.length) {
      final next = value.codeUnitAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        i++; // A valid pair.
        continue;
      }
    }
    (units ??= value.codeUnits.toList())[i] = 0xFFFD;
  }
  return units == null ? value : String.fromCharCodes(units);
}
