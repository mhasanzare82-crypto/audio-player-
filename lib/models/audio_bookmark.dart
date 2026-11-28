class AudioBookmark {
  const AudioBookmark({
    required this.id,
    required this.audioPath,
    required this.audioTitle,
    required this.positionMs,
    required this.createdAt,
    this.title = '',
    this.topic = '',
    this.endPositionMs,
    this.isTopicRange = false,
    this.isFullTrack = false,
  });

  final String id;
  final String audioPath;
  final String audioTitle;
  final int positionMs;
  final DateTime createdAt;
  final String title;
  final String topic;
  final int? endPositionMs;
  final bool isTopicRange;
  final bool isFullTrack;

  Map<String, dynamic> toJson() => {
        'id': id,
        'audioPath': audioPath,
        'audioTitle': audioTitle,
        'positionMs': positionMs,
        'createdAt': createdAt.toIso8601String(),
        'title': title,
        'topic': topic,
        'endPositionMs': endPositionMs,
        'isTopicRange': isTopicRange,
        'isFullTrack': isFullTrack,
      };

  factory AudioBookmark.fromJson(Map<String, dynamic> json) {
    return AudioBookmark(
      id: json['id'] as String,
      audioPath: json['audioPath'] as String,
      audioTitle: json['audioTitle'] as String,
      positionMs: (json['positionMs'] as num).toInt(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      title: json['title']?.toString() ?? '',
      topic: json['topic']?.toString() ?? '',
      endPositionMs: (json['endPositionMs'] as num?)?.toInt(),
      isTopicRange: json['isTopicRange'] == true,
      isFullTrack: json['isFullTrack'] == true,
    );
  }
}
