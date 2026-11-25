import 'package:flutter/services.dart';

class ScheduledPlaybackService {
  static const MethodChannel _channel =
      MethodChannel('com.mhasanzare82.audioplayer/scheduled_playback');

  static Future<void> setStopHandler(Future<void> Function() handler) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'scheduledStopFired') await handler();
    });
  }

  static Future<void> scheduleStart({
    required String path,
    required String title,
    required DateTime at,
  }) => _channel.invokeMethod<void>('scheduleStart', {
        'path': path,
        'title': title,
        'triggerAtMillis': at.millisecondsSinceEpoch,
      });

  static Future<void> scheduleStop({required DateTime at}) =>
      _channel.invokeMethod<void>('scheduleStop', {
        'triggerAtMillis': at.millisecondsSinceEpoch,
      });

  static Future<void> cancelStart() =>
      _channel.invokeMethod<void>('cancelStart');

  static Future<void> cancelStop() =>
      _channel.invokeMethod<void>('cancelStop');
}
