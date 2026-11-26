class VolumeRange {
  const VolumeRange({
    required this.startMs,
    required this.endMs,
    required this.percent,
  });

  final int startMs;
  final int endMs;
  final int percent;

  Map<String, dynamic> toMap() => {
        'startMs': startMs,
        'endMs': endMs,
        'percent': percent,
      };

  factory VolumeRange.fromMap(Map<String, dynamic> map) => VolumeRange(
        startMs: (map['startMs'] as num).toInt(),
        endMs: (map['endMs'] as num).toInt(),
        percent: (map['percent'] as num).toInt().clamp(0, 100),
      );
}

double scheduledVolumeAt(
  List<VolumeRange> ranges,
  int positionMs,
  double fallback,
) {
  var result = fallback;
  for (final range in ranges) {
    if (positionMs >= range.startMs) {
      result = range.percent / 100;
    } else {
      break;
    }
  }
  return result.clamp(0.0, 1.0).toDouble();
}
