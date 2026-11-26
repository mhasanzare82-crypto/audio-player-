import 'package:flutter_test/flutter_test.dart';
import 'package:audio_player/models/volume_automation_profile.dart';
import 'package:audio_player/services/volume_automation_controller.dart';

void main() {
  group('multi-pattern volume automation', () {
    late VolumeAutomationController controller;
    late List<double> emitted;

    VolumeAutomationProfile profile(int durationMs, double volume) {
      return VolumeAutomationProfile(
        durationMs: durationMs,
        repeat: false,
        points: [
          VolumeAutomationPoint(timeMs: 0, volume: volume),
          VolumeAutomationPoint(timeMs: durationMs, volume: volume),
        ],
      );
    }

    setUp(() {
      emitted = [];
      controller = VolumeAutomationController(
        onVolumeChanged: emitted.add,
      );
    });

    tearDown(() => controller.dispose());

    test('repeats the complete sequence at original pattern durations', () {
      final first = VolumeAutomationPattern(
        id: 'first',
        name: 'First',
        profile: profile(4000, 0.5),
      );
      final second = VolumeAutomationPattern(
        id: 'second',
        name: 'Second',
        profile: profile(3000, 0.2),
      );

      controller.startSequence(
        sequence: const [
          VolumeAutomationSequenceItem(id: 'a', patternId: 'first'),
          VolumeAutomationSequenceItem(id: 'b', patternId: 'second'),
        ],
        patterns: [first, second],
        audioDurationMs: 20000,
      );

      controller.updatePlaybackPosition(Duration.zero, isPlaying: true);
      expect(controller.currentValue.value, closeTo(0.5, 0.001));

      controller.updatePlaybackPosition(
        const Duration(milliseconds: 3999),
        isPlaying: true,
      );
      expect(controller.currentValue.value, closeTo(0.5, 0.001));

      controller.updatePlaybackPosition(
        const Duration(milliseconds: 4000),
        isPlaying: true,
      );
      expect(controller.currentValue.value, closeTo(0.2, 0.001));

      controller.updatePlaybackPosition(
        const Duration(milliseconds: 7000),
        isPlaying: true,
      );
      expect(controller.currentValue.value, closeTo(0.5, 0.001));

      controller.updatePlaybackPosition(
        const Duration(milliseconds: 11000),
        isPlaying: true,
      );
      expect(controller.currentValue.value, closeTo(0.2, 0.001));

      controller.updatePlaybackPosition(
        const Duration(milliseconds: 14000),
        isPlaying: true,
      );
      expect(controller.currentValue.value, closeTo(0.5, 0.001));
      expect(controller.isRunning.value, isTrue);
    });

    test('stops sequence at audio end even during a repeated cycle', () {
      final first = VolumeAutomationPattern(
        id: 'first',
        name: 'First',
        profile: profile(4000, 0.5),
      );
      final second = VolumeAutomationPattern(
        id: 'second',
        name: 'Second',
        profile: profile(3000, 0.2),
      );
      controller.startSequence(
        sequence: const [
          VolumeAutomationSequenceItem(id: 'a', patternId: 'first'),
          VolumeAutomationSequenceItem(id: 'b', patternId: 'second'),
        ],
        patterns: [first, second],
        audioDurationMs: 10000,
      );

      controller.updatePlaybackPosition(
        const Duration(milliseconds: 9999),
        isPlaying: true,
      );
      expect(controller.isRunning.value, isTrue);
      controller.updatePlaybackPosition(
        const Duration(milliseconds: 10000),
        isPlaying: true,
      );
      expect(controller.isRunning.value, isFalse);
      expect(controller.currentValue.value, closeTo(1, 0.001));
    });

    test('legacy profile values are migrated to the 0–50 percent range', () {
      final migrated = VolumeAutomationProfile.fromJson(
        '{"durationMs":1000,"repeat":false,"points":['
        '{"timeMs":0,"volume":1},'
        '{"timeMs":1000,"volume":0.5}]}',
      );
      expect(migrated.points.first.volume, closeTo(0.5, 0.001));
      expect(migrated.points.last.volume, closeTo(0.25, 0.001));
    });
  });
}
