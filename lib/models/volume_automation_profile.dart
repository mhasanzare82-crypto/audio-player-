import 'dart:convert';

class VolumeAutomationPoint {
  const VolumeAutomationPoint({
    required this.timeMs,
    required this.volume,
  });

  final int timeMs;
  final double volume;

  Map<String, dynamic> toMap() => {
        'timeMs': timeMs,
        'volume': volume,
      };

  factory VolumeAutomationPoint.fromMap(Map<String, dynamic> map) {
    return VolumeAutomationPoint(
      timeMs: (map['timeMs'] as num).round(),
      volume: (map['volume'] as num).toDouble().clamp(0.0, 1.0).toDouble(),
    );
  }
}

class VolumeAutomationProfile {
  VolumeAutomationProfile({
    required this.durationMs,
    required this.repeat,
    required List<VolumeAutomationPoint> points,
  }) : points = List<VolumeAutomationPoint>.unmodifiable(
          [...points]..sort((a, b) => a.timeMs.compareTo(b.timeMs)),
        ) {
    if (durationMs < 1000) {
      throw ArgumentError.value(durationMs, 'durationMs', 'Must be at least 1 second.');
    }
    if (this.points.length < 2 ||
        this.points.first.timeMs != 0 ||
        this.points.last.timeMs != durationMs) {
      throw ArgumentError('A curve must have fixed start and end points.');
    }
    for (var i = 0; i < this.points.length; i++) {
      final point = this.points[i];
      if (point.timeMs < 0 || point.timeMs > durationMs ||
          point.volume < 0 || point.volume > 1 ||
          (i > 0 && point.timeMs <= this.points[i - 1].timeMs)) {
        throw ArgumentError('Curve points must be ordered and inside the graph.');
      }
    }
  }

  final int durationMs;
  final bool repeat;
  final List<VolumeAutomationPoint> points;

  static VolumeAutomationProfile get defaultProfile => VolumeAutomationProfile(
        durationMs: 30000,
        repeat: false,
        points: const [
          VolumeAutomationPoint(timeMs: 0, volume: 1),
          VolumeAutomationPoint(timeMs: 30000, volume: 1),
        ],
      );

  String toJson() => jsonEncode({
        'durationMs': durationMs,
        'repeat': repeat,
        'points': points.map((point) => point.toMap()).toList(),
      });

  factory VolumeAutomationProfile.fromJson(String source) {
    final map = jsonDecode(source) as Map<String, dynamic>;
    final duration = (map['durationMs'] as num).round();
    final rawPoints = map['points'] as List<dynamic>;
    final points = rawPoints
        .map((item) => VolumeAutomationPoint.fromMap(
              Map<String, dynamic>.from(item as Map),
            ))
        .toList();
    return VolumeAutomationProfile(
      durationMs: duration,
      repeat: map['repeat'] as bool? ?? false,
      points: points,
    );
  }

  VolumeAutomationProfile copyWith({
    int? durationMs,
    bool? repeat,
    List<VolumeAutomationPoint>? points,
  }) {
    return VolumeAutomationProfile(
      durationMs: durationMs ?? this.durationMs,
      repeat: repeat ?? this.repeat,
      points: points ?? this.points,
    );
  }

  double valueAt(int elapsedMs) {
    final time = elapsedMs.clamp(0, durationMs);
    if (time <= points.first.timeMs) return points.first.volume;
    if (time >= points.last.timeMs) return points.last.volume;

    var segment = 0;
    for (var i = 0; i < points.length - 1; i++) {
      if (time <= points[i + 1].timeMs) {
        segment = i;
        break;
      }
    }

    final start = points[segment];
    final end = points[segment + 1];
    final progress =
        (time - start.timeMs) / (end.timeMs - start.timeMs);
    // Linear interpolation preserves the exact shape the user drew:
    // no sine wave, easing, or curve smoothing is introduced.
    return (start.volume + (end.volume - start.volume) * progress)
        .clamp(0.0, 1.0)
        .toDouble();
  }
}
