import 'dart:convert';

class AudioTrack {
  const AudioTrack({
    required this.path,
    required this.title,
  });

  final String path;
  final String title;

  Map<String, dynamic> toJson() => {'path': path, 'title': title};

  factory AudioTrack.fromJson(Map<String, dynamic> json) {
    return AudioTrack(
      path: json['path'] as String,
      title: json['title'] as String,
    );
  }

  static String encodeList(List<AudioTrack> tracks) =>
      jsonEncode(tracks.map((track) => track.toJson()).toList());

  static List<AudioTrack> decodeList(String? source) {
    if (source == null || source.isEmpty) return [];
    final decoded = jsonDecode(source) as List<dynamic>;
    return decoded
        .map((item) => AudioTrack.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}
