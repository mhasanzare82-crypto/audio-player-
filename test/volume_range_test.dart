import 'package:flutter_test/flutter_test.dart';
import 'package:audio_player/models/volume_range.dart';

void main() {
  group('scheduledVolumeAt', () {
    const ranges = [
      VolumeRange(startMs: 60000, endMs: 120000, percent: 15),
      VolumeRange(startMs: 300000, endMs: 480000, percent: 5),
      VolumeRange(startMs: 600000, endMs: 690000, percent: 30),
    ];

    test('keeps the base volume before the first scheduled range', () {
      expect(scheduledVolumeAt(ranges, 0, 0.8), closeTo(0.8, 0.0001));
      expect(scheduledVolumeAt(ranges, 59999, 0.8), closeTo(0.8, 0.0001));
    });

    test('keeps the selected volume after range end until the next range', () {
      expect(scheduledVolumeAt(ranges, 60000, 0.8), closeTo(0.15, 0.0001));
      expect(scheduledVolumeAt(ranges, 120000, 0.8), closeTo(0.15, 0.0001));
      expect(scheduledVolumeAt(ranges, 299999, 0.8), closeTo(0.15, 0.0001));
      expect(scheduledVolumeAt(ranges, 300000, 0.8), closeTo(0.05, 0.0001));
      expect(scheduledVolumeAt(ranges, 500000, 0.8), closeTo(0.05, 0.0001));
      expect(scheduledVolumeAt(ranges, 600000, 0.8), closeTo(0.30, 0.0001));
      expect(scheduledVolumeAt(ranges, 900000, 0.8), closeTo(0.30, 0.0001));
    });
  });
}
