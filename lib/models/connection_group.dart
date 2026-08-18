import 'dart:convert';

class ConnectionGroup {
  final String id;
  final String name;
  final String? parentId;

  ConnectionGroup({
    required this.id,
    required this.name,
    this.parentId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'parentId': parentId,
    };
  }

  factory ConnectionGroup.fromMap(Map<String, dynamic> map) {
    return ConnectionGroup(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      parentId: map['parentId'],
    );
  }

  String toJson() => json.encode(toMap());

  factory ConnectionGroup.fromJson(String source) => ConnectionGroup.fromMap(json.decode(source));
}
