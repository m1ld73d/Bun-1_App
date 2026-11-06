class Board {
  final String id;   // BLE remote ID string
  final String name; // BLE advertised name

  const Board({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory Board.fromJson(Map<String, dynamic> json) => Board(
        id: json['id'] as String,
        name: json['name'] as String,
      );

  @override
  bool operator ==(Object other) => other is Board && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Board(id: $id, name: $name)';
}
