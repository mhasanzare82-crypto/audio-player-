import 'package:flutter/services.dart';

class MixerNotificationService {
  static const MethodChannel _channel =
      MethodChannel('com.mhasanzare82.audioplayer/mixer_notification');
  static VoidCallback? _openPanelHandler;
  static bool _handlerRegistered = false;

  static void setOpenPanelHandler(VoidCallback handler) {
    _openPanelHandler = handler;
    if (_handlerRegistered) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openMixerPanel') {
        _openPanelHandler?.call();
      }
    });
    _handlerRegistered = true;
    _channel.invokeMethod<void>('ready').catchError((_) {});
  }

  static void clearOpenPanelHandler() {
    _openPanelHandler = null;
  }

  static Future<void> show() async {
    try {
      await _channel.invokeMethod<void>('show');
    } on PlatformException {
      // Notification permission may be denied by the user or unavailable.
    } on MissingPluginException {
      // The app can still use the in-app floating controls.
    }
  }

  static Future<void> hide() async {
    try {
      await _channel.invokeMethod<void>('hide');
    } on PlatformException {
      // Ignore notification teardown failures.
    } on MissingPluginException {
      // Native notification integration is Android-only.
    }
  }
}
