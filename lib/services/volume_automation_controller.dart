import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/volume_automation_profile.dart';

class VolumeAutomationController {
  VolumeAutomationController({required this.onVolumeChanged});

  final ValueChanged<double> onVolumeChanged;
  final ValueNotifier<bool> isRunning = ValueNotifier<bool>(false);
  final ValueNotifier<double> currentValue = ValueNotifier<double>(1);

  Timer? _timer;
  Stopwatch? _stopwatch;
  VolumeAutomationProfile? _profile;

  void start(VolumeAutomationProfile profile) {
    _timer?.cancel();
    _stopwatch?.stop();
    _profile = profile;
    _stopwatch = Stopwatch()..start();
    isRunning.value = true;
    _emit(profile.valueAt(0));
    _timer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      final activeProfile = _profile;
      final watch = _stopwatch;
      if (activeProfile == null || watch == null) return;

      final elapsed = watch.elapsedMilliseconds;
      if (!activeProfile.repeat && elapsed >= activeProfile.durationMs) {
        _emit(activeProfile.valueAt(activeProfile.durationMs));
        _timer?.cancel();
        _timer = null;
        watch.stop();
        isRunning.value = false;
        return;
      }

      final position = activeProfile.repeat
          ? elapsed % activeProfile.durationMs
          : elapsed;
      _emit(activeProfile.valueAt(position));
    });
  }

  void stop({bool restoreBaseVolume = true}) {
    _timer?.cancel();
    _timer = null;
    _stopwatch?.stop();
    _stopwatch = null;
    _profile = null;
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
