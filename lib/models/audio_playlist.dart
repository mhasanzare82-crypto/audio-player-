import 'dart:convert';

class AudioPlaylist {
  const AudioPlaylist({
    required this.id,
    required this.name,
    required this.trackPaths,
  });

  final String id;
  final String name;
  final List<String> trackPaths;

  AudioPlaylist copyWith({String? name, List<String>? trackPaths}) =>
      AudioPlaylist(
        id: id,
        name: name ?? this.name,
        trackPaths: trackPaths ?? this.trackPaths,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'trackPaths': trackPaths,
      };

  factory AudioPlaylist.fromJson(Map<String, dynamic> json) => AudioPlaylist(
        id: json['id'] as String,
        name: json['name'] as String,
        trackPaths: (json['trackPaths'] as List<dynamic>? ?? [])
            .whereType<String>()
            .toList(),
      );

  static String encodeList(List<AudioPlaylist> items) =>
      jsonEncode(items.map((item) => item.toJson()).toList());

  static List<AudioPlaylist> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    return (jsonDecode(raw) as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map(AudioPlaylist.fromJson)
        .toList();
  }
}
