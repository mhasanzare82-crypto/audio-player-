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

    final p1 = points[segment];
    final p2 = points[segment + 1];
    final p0 = segment > 0 ? points[segment - 1] : p1;
    final p3 = segment + 2 < points.length ? points[segment + 2] : p2;
    final span = (p2.timeMs - p1.timeMs).toDouble();
    final t = ((time - p1.timeMs) / span).clamp(0.0, 1.0);
    final t2 = t * t;
    final t3 = t2 * t;

    final slope1 = segment > 0 && p2.timeMs != p0.timeMs
        ? (p2.volume - p0.volume) / (p2.timeMs - p0.timeMs)
        : (p2.volume - p1.volume) / span;
    final slope2 = segment + 2 < points.length && p3.timeMs != p1.timeMs
        ? (p3.volume - p1.volume) / (p3.timeMs - p1.timeMs)
        : (p2.volume - p1.volume) / span;

    final m1 = slope1 * span;
    final m2 = slope2 * span;
    final value = (2 * t3 - 3 * t2 + 1) * p1.volume +
        (t3 - 2 * t2 + t) * m1 +
        (-2 * t3 + 3 * t2) * p2.volume +
        (t3 - t2) * m2;

    return value
        .clamp(
          p1.volume < p2.volume ? p1.volume : p2.volume,
          p1.volume > p2.volume ? p1.volume : p2.volume,
        )
        .toDouble();
  }
}
