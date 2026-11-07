import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';


/// One-off, user-created recording schedule. It never starts the microphone
/// invisibly: when RAVEN is not active Android posts a silent, visible alert.
class ScheduledRecording {
  const ScheduledRecording({
    required this.id,
    required this.title,
    required this.scheduledAt,
  });

  final String id;
  final String title;
  final DateTime scheduledAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'scheduledAt': scheduledAt.toIso8601String(),
      };

  factory ScheduledRecording.fromJson(Map<String, Object?> json) {
    return ScheduledRecording(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Scheduled recording',
      scheduledAt: DateTime.parse(json['scheduledAt'] as String),
    );
  }
}

class ScheduledRecordingService {
  static const String _storageKey = 'raven.scheduledRecordings.v1';
  static const MethodChannel _channel = MethodChannel('raven/scheduled_recording');
  static const Uuid _uuid = Uuid();

  bool get _hasAndroidAlarmBridge => Platform.isAndroid;

  Future<File> _scheduleFile() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final ravenDirectory = Directory('${supportDirectory.path}/raven');
    await ravenDirectory.create(recursive: true);
    return File('${ravenDirectory.path}/scheduled_recordings.json');
  }

  List<ScheduledRecording>? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map((item) => ScheduledRecording.fromJson(Map<String, Object?>.from(item)))
          .toList()
        ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<List<ScheduledRecording>> list() async {
    final canonical = await _scheduleFile();
    final backup = File('${canonical.path}.bak');
    final temporary = File('${canonical.path}.tmp');
    for (final candidate in <File>[canonical, backup, temporary]) {
      if (!await candidate.exists()) continue;
      try {
        final decoded = _decode(await candidate.readAsString());
        if (decoded == null) continue;
        if (candidate.path != canonical.path) {
          try {
            await candidate.copy(canonical.path);
          } on FileSystemException {
            // The recovered schedule is still usable in memory.
          }
        }
        return decoded;
      } on FileSystemException {
        // Try the next recovery candidate.
      }
    }

    // Migrate schedules created by the earlier development build, if any.
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_storageKey);
    final migrated = legacy == null ? null : _decode(legacy);
    if (migrated != null && migrated.isNotEmpty) {
      await _persist(migrated);
      return migrated;
    }
    return <ScheduledRecording>[];
  }

  Future<void> _persist(List<ScheduledRecording> schedules) async {
    final canonical = await _scheduleFile();
    final temporary = File('${canonical.path}.tmp');
    final backup = File('${canonical.path}.bak');
    final payload = jsonEncode(schedules.map((item) => item.toJson()).toList());

    await temporary.writeAsString(payload, flush: true);
    try {
      if (await backup.exists()) await backup.delete();
      if (await canonical.exists()) await canonical.copy(backup.path);
      if (await canonical.exists()) await canonical.delete();
      await temporary.rename(canonical.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await canonical.exists() && await backup.exists()) {
        try { await backup.copy(canonical.path); } on FileSystemException { /* backup remains available */ }
      }
      rethrow;
    }
  }

  Future<ScheduledRecording> create({required String title, required DateTime at}) async {
    if (!at.isAfter(DateTime.now().add(const Duration(seconds: 5)))) {
      throw ArgumentError('Choose a time at least a few seconds in the future.');
    }

    if (_hasAndroidAlarmBridge) {
      final notificationsAllowed = await _channel.invokeMethod<bool>('requestNotificationPermission') ?? false;
      if (!notificationsAllowed) {
        throw StateError('Notifications are required so RAVEN can alert you at the scheduled time.');
      }
      final exactAllowed = await _channel.invokeMethod<bool>('canScheduleExactAlarms') ?? false;
      if (!exactAllowed) {
        await _channel.invokeMethod<void>('openExactAlarmSettings');
        throw const ExactAlarmPermissionRequired();
      }
    }

    final cleanTitle = title.trim().isEmpty ? 'Scheduled recording' : title.trim();
    final entry = ScheduledRecording(
      id: _uuid.v4(),
      title: cleanTitle,
      scheduledAt: at,
    );
    final schedules = await list();
    // Prevent two alarms from trying to open the recorder at almost the same time.
    final collision = schedules.any((item) => item.scheduledAt.difference(at).inMinutes.abs() < 2);
    if (collision) throw StateError('Another recording is already scheduled within two minutes of that time.');

    if (_hasAndroidAlarmBridge) {
      await _channel.invokeMethod<void>('scheduleAlarm', <String, Object?>{
        'id': entry.id,
        'title': entry.title,
        'triggerAtMillis': at.millisecondsSinceEpoch,
      });
    }
    schedules.add(entry);
    schedules.sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    try {
      await _persist(schedules);
    } catch (_) {
      await _cancelNative(entry.id);
      rethrow;
    }
    return entry;
  }

  Future<void> cancel(String id) async {
    final schedules = await list();
    schedules.removeWhere((item) => item.id == id);
    await _persist(schedules);
    if (_hasAndroidAlarmBridge) {
      try {
        await _channel.invokeMethod<void>('cancelAlarm', <String, Object?>{'id': id});
      } on PlatformException {
        // Persistence remains authoritative; a missing system alarm is harmless.
      } on MissingPluginException {
        // Useful for tests or a partially configured development build.
      }
    }
  }

  /// Consumes a schedule from a tap on RAVEN's visible Android notification.
  /// A 15-minute grace period avoids surprising recordings long after the alarm.
  Future<ScheduledRecording?> takeFromNotification(String id, {DateTime? now}) async {
    final clock = now ?? DateTime.now();
    final schedules = await list();
    ScheduledRecording? selected;
    final expired = schedules.where((item) => clock.difference(item.scheduledAt) > const Duration(minutes: 15)).toList();
    for (final item in schedules) {
      if (item.id == id) {
        final age = clock.difference(item.scheduledAt);
        if (!age.isNegative && age <= const Duration(minutes: 15)) selected = item;
      }
    }
    schedules.removeWhere((item) => item.id == id || expired.any((old) => old.id == item.id));
    await _persist(schedules);
    await _cancelNative(id);
    for (final item in expired) {
      await _cancelNative(item.id);
    }
    return selected;
  }

  /// Consumes an alarm only when RAVEN is already foregrounded at the due time.
  /// A small window avoids auto-starting merely because the user opens RAVEN hours later.
  Future<ScheduledRecording?> takeDueWhileOpen({DateTime? now}) async {
    final clock = now ?? DateTime.now();
    final schedules = await list();
    ScheduledRecording? selected;
    for (final item in schedules) {
      final age = clock.difference(item.scheduledAt);
      if (!age.isNegative && age <= const Duration(seconds: 30)) {
        selected = item;
        break;
      }
    }
    final expired = schedules.where((item) => clock.difference(item.scheduledAt) > const Duration(minutes: 15)).toList();
    if (selected == null && expired.isEmpty) return null;
    schedules.removeWhere((item) => item.id == selected?.id || expired.any((old) => old.id == item.id));
    await _persist(schedules);
    if (selected != null) await _cancelNative(selected.id);
    for (final item in expired) {
      await _cancelNative(item.id);
    }
    return selected;
  }

  Future<String?> consumeNotificationLaunchId() async {
    if (!_hasAndroidAlarmBridge) return null;
    try {
      return await _channel.invokeMethod<String>('consumeTappedScheduleId');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _cancelNative(String id) async {
    if (!_hasAndroidAlarmBridge) return;
    try {
      await _channel.invokeMethod<void>('cancelAlarm', <String, Object?>{'id': id});
    } on PlatformException {
      // A cancelled or already-fired alarm is fine.
    } on MissingPluginException {
      // Allow service-model tests without the Android platform bridge.
    }
  }
}

class ExactAlarmPermissionRequired implements Exception {
  const ExactAlarmPermissionRequired();

  @override
  String toString() => 'Exact alarm permission is required. Enable Alarms & reminders and try again.';
}
