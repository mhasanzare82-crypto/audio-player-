import 'package:flutter/foundation.dart';

import '../models/volume_automation_profile.dart';

class VolumeAutomationController {
  VolumeAutomationController({required this.onVolumeChanged});

  final ValueChanged<double> onVolumeChanged;
  final ValueNotifier<bool> isRunning = ValueNotifier<bool>(false);
  final ValueNotifier<double> currentValue = ValueNotifier<double>(1);

  VolumeAutomationProfile? _profile;
  int _elapsedMs = 0;
  int? _lastPositionMs;
  bool _wasPlaying = false;

  /// Arms a curve. Its clock advances only when the audio player's position
  /// advances, so pausing or buffering the player pauses the automation too.
  void start(VolumeAutomationProfile profile) {
    _profile = profile;
    _elapsedMs = 0;
    _lastPositionMs = null;
    _wasPlaying = false;
    isRunning.value = true;
    _emit(profile.valueAt(0));
  }

  /// Feed this from the audio player's position stream.
  ///
  /// Large jumps are treated as seeks rather than playback time. This keeps
  /// scrubbing forward/backward from unexpectedly consuming the curve.
  void updatePlaybackPosition(
    Duration position, {
    required bool isPlaying,
  }) {
    if (!isRunning.value) return;
    final activeProfile = _profile;
    if (activeProfile == null) return;

    final positionMs = position.inMilliseconds;
    if (!isPlaying) {
      _lastPositionMs = positionMs;
      _wasPlaying = false;
      return;
    }

    if (!_wasPlaying || _lastPositionMs == null) {
      _lastPositionMs = positionMs;
      _wasPlaying = true;
      return;
    }

    final delta = positionMs - _lastPositionMs!;
    _lastPositionMs = positionMs;
    _wasPlaying = true;

    // Position stream normally emits several times per second. Ignore large
    // discontinuities (manual seeks / track jumps) instead of counting them.
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

  void stop({bool restoreBaseVolume = true}) {
    _profile = null;
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
