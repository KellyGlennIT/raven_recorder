import 'dart:io';

import 'package:flutter/services.dart';

class RecordingNotificationService {
  static const MethodChannel _channel =
      MethodChannel('raven/recording_controls');
  static const MethodChannel _permissionChannel =
      MethodChannel('raven/recording_permissions');

  static void setActionHandler(Future<void> Function(String action)? handler) {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (handler != null &&
          (call.method == 'pause' || call.method == 'stop')) {
        await handler(call.method);
      }
    });
  }

  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    return await _permissionChannel
            .invokeMethod<bool>('requestNotificationPermission') ??
        false;
  }

  Future<void> start({
    required String title,
    required int elapsedMs,
    required bool paused,
  }) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('start', <String, Object?>{
      'title': title,
      'elapsedMs': elapsedMs,
      'paused': paused,
    });
  }

  Future<void> update({
    required String title,
    required int elapsedMs,
    required bool paused,
  }) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('update', <String, Object?>{
      'title': title,
      'elapsedMs': elapsedMs,
      'paused': paused,
    });
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stop');
  }
}
