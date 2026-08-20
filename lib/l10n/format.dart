import 'l10n.dart';

/// How long ago [when] was, in words.
///
/// Used wherever a timestamp is shown as context rather than as data — the last
/// time a profile was connected to, when a connection dropped. An absolute
/// clock time would make the reader do the subtraction; "hace 5 min" is the
/// thing they actually wanted to know.
///
/// Falls back to a plain date past a week, where "hace 43 días" stops being
/// easier to read than the date itself.
String relativeTime(DateTime when, {DateTime? now}) {
  final delta = (now ?? DateTime.now()).difference(when);

  if (delta.isNegative) return tr('ahora');
  if (delta.inSeconds < 45) return tr('ahora');
  if (delta.inMinutes < 60) return tr('hace {0} min', [delta.inMinutes]);
  if (delta.inHours < 24) return tr('hace {0} h', [delta.inHours]);
  if (delta.inDays == 1) return tr('ayer');
  if (delta.inDays < 7) return tr('hace {0} días', [delta.inDays]);

  return '${when.day.toString().padLeft(2, '0')}/'
      '${when.month.toString().padLeft(2, '0')}/${when.year}';
}
