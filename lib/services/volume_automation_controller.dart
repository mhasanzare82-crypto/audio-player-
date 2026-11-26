import 'package:flutter/foundation.dart';

import '../models/volume_automation_profile.dart';

class VolumeAutomationController {
  VolumeAutomationController({required this.onVolumeChanged});

  final ValueChanged<double> onVolumeChanged;
  final ValueNotifier<bool> isRunning = ValueNotifier<bool>(false);
  final ValueNotifier<double> currentValue = ValueNotifier<double>(1);

  VolumeAutomationProfile? _profile;
  List<VolumeAutomationSequenceItem> _sequence = const [];
  Map<String, VolumeAutomationPattern> _patterns = const {};
  int? _audioDurationMs;
  int _elapsedMs = 0;
  int? _lastPositionMs;
  bool _wasPlaying = false;

  void start(VolumeAutomationProfile profile) {
    _sequence = const [];
    _patterns = const {};
    _audioDurationMs = null;
    _profile = profile;
    _elapsedMs = 0;
    _lastPositionMs = null;
    _wasPlaying = false;
    isRunning.value = true;
    _emit(profile.valueAt(0));
  }

  void startSequence({
    required List<VolumeAutomationSequenceItem> sequence,
    required List<VolumeAutomationPattern> patterns,
    required int audioDurationMs,
  }) {
    final available = {for (final pattern in patterns) pattern.id: pattern};
    final validSequence = sequence
        .where((item) => available.containsKey(item.patternId))
        .toList(growable: false);
    if (validSequence.isEmpty) {
      stop();
      return;
    }
    _profile = null;
    _sequence = validSequence;
    _patterns = available;
    _audioDurationMs = audioDurationMs > 0 ? audioDurationMs : null;
    _elapsedMs = 0;
    _lastPositionMs = null;
    _wasPlaying = false;
    isRunning.value = true;
    _emit(_patterns[_sequence.first.patternId]!.profile.valueAt(0));
  }

  void updatePlaybackPosition(Duration position, {required bool isPlaying}) {
    if (!isRunning.value) return;
    if (!isPlaying) {
      _lastPositionMs = position.inMilliseconds;
      _wasPlaying = false;
      return;
    }

    if (_sequence.isNotEmpty) {
      _updateSequence(position.inMilliseconds);
      return;
    }

    final activeProfile = _profile;
    if (activeProfile == null) return;
    final positionMs = position.inMilliseconds;
    if (!_wasPlaying || _lastPositionMs == null) {
      _lastPositionMs = positionMs;
      _wasPlaying = true;
      return;
    }
    final delta = positionMs - _lastPositionMs!;
    _lastPositionMs = positionMs;
    _wasPlaying = true;
    if (delta <= 0 || delta > 2000) return;
    _elapsedMs += delta;
    if (!activeProfile.repeat && _elapsedMs >= activeProfile.durationMs) {
      _elapsedMs = activeProfile.durationMs;
      _emit(activeProfile.valueAt(_elapsedMs));
      isRunning.value = false;
      _profile = null;
      _wasPlaying = false;
      _lastPositionMs = null;
      return;
    }
    final curvePosition = activeProfile.repeat
        ? _elapsedMs % activeProfile.durationMs
        : _elapsedMs;
    _emit(activeProfile.valueAt(curvePosition));
  }

  void _updateSequence(int audioPositionMs) {
    var totalDuration = 0;
    for (final item in _sequence) {
      totalDuration += _patterns[item.patternId]!.profile.durationMs;
    }
    if (totalDuration <= 0) {
      stop();
      return;
    }

    final scale = (_audioDurationMs != null && totalDuration > _audioDurationMs!)
        ? _audioDurationMs! / totalDuration
        : 1.0;
    var cursor = 0.0;
    for (final item in _sequence) {
      final pattern = _patterns[item.patternId]!;
      final segmentDuration = pattern.profile.durationMs * scale;
      final segmentEnd = cursor + segmentDuration;
      if (audioPositionMs < segmentEnd) {
        final localMs = (audioPositionMs - cursor).clamp(0.0, segmentDuration);
        final patternPosition = segmentDuration <= 0
            ? 0
            : (localMs / segmentDuration * pattern.profile.durationMs).round();
        final sampledPosition = pattern.profile.repeat
            ? patternPosition % pattern.profile.durationMs
            : patternPosition.clamp(0, pattern.profile.durationMs).toInt();
        _emit(pattern.profile.valueAt(sampledPosition));
        return;
      }
      cursor = segmentEnd;
    }

    _emit(_patterns[_sequence.last.patternId]!.profile.valueAt(
      _patterns[_sequence.last.patternId]!.profile.durationMs,
    ));
    isRunning.value = false;
    _sequence = const [];
    _patterns = const {};
    _audioDurationMs = null;
    _wasPlaying = false;
    _lastPositionMs = null;
  }

  void stop({bool restoreBaseVolume = true}) {
    _profile = null;
    _sequence = const [];
    _patterns = const {};
    _audioDurationMs = null;
    _elapsedMs = 0;
    _lastPositionMs = null;
    _wasPlaying = false;
    isRunning.value = false;
    if (restoreBaseVolume) _emit(1);
  }

  void _emit(double value) {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    currentValue.value = normalized;
    onVolumeChanged(normalized);
  }

  void dispose() {
    stop();
    isRunning.dispose();
    currentValue.dispose();
  }
}
