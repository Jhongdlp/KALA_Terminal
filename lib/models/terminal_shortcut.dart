
class TerminalShortcut {
  final String label;
  final String value;

  TerminalShortcut({
    required this.label,
    required this.value,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'value': value,
      };

  factory TerminalShortcut.fromJson(Map<String, dynamic> json) =>
      TerminalShortcut(
        label: json['label'] as String,
        value: json['value'] as String,
      );

  /// Decodes backslash escape sequences like \n, \t, \e, or hex escapes like \x03.
  String get parsedValue {
    var result = value;
    result = result
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\r')
        .replaceAll(r'\t', '\t')
        .replaceAll(r'\b', '\b')
        .replaceAll(r'\f', '\f')
        .replaceAll(r'\e', '\x1b');

    // Replace hex escapes like \x1b or \x03
    final hexRegex = RegExp(r'\\x([0-9a-fA-F]{2})');
    result = result.replaceAllMapped(hexRegex, (match) {
      final hexCode = match.group(1)!;
      final charCode = int.parse(hexCode, radix: 16);
      return String.fromCharCode(charCode);
    });

    return result;
  }
}
