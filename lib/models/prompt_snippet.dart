import 'dart:convert';

/// A reusable prompt template the user can insert into the terminal with one
/// tap — the fastest way to send a recurring instruction to a TUI agent
/// (Claude Code, aider, …) without typing it on a phone keyboard.
class PromptSnippet {
  final String id;
  final String title;
  final String text;

  PromptSnippet({
    required this.id,
    required this.title,
    required this.text,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'text': text,
      };

  factory PromptSnippet.fromMap(Map<String, dynamic> map) => PromptSnippet(
        id: map['id'] ?? '',
        title: map['title'] ?? '',
        text: map['text'] ?? '',
      );

  String toJson() => json.encode(toMap());

  factory PromptSnippet.fromJson(String source) =>
      PromptSnippet.fromMap(json.decode(source));
}
