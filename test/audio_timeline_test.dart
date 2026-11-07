import 'package:flutter_test/flutter_test.dart';
import 'package:raven/models/raven_project.dart';
import 'package:raven/services/audio_timeline.dart';

void main() {
  final start = DateTime.utc(2026, 10, 29);
  final sessions = <RavenAudioSession>[
    RavenAudioSession(
      id: 'one', audioPath: '/one.m4a', createdAt: start,
      durationMs: 60000,
    ),
    RavenAudioSession(
      id: 'two', audioPath: '/two.m4a', createdAt: start.add(const Duration(hours: 1)),
      durationMs: 30000,
    ),
    RavenAudioSession(
      id: 'three', audioPath: '/three.m4a', createdAt: start.add(const Duration(hours: 2)),
      durationMs: 10000,
    ),
  ];

  test('exposes several internal sessions as one project duration', () {
    expect(AudioTimeline.totalDurationMs(sessions), 100000);
  });

  test('maps a global seek into the correct internal session', () {
    expect(AudioTimeline.locate(sessions, 0), (index: 0, localMs: 0));
    expect(AudioTimeline.locate(sessions, 65000), (index: 1, localMs: 5000));
    expect(AudioTimeline.locate(sessions, 90000), (index: 2, localMs: 0));
    expect(AudioTimeline.locate(sessions, 100000), (index: 2, localMs: 10000));
  });

  test('maps session index to its global timeline offset', () {
    expect(AudioTimeline.offsetOf(sessions, 0), 0);
    expect(AudioTimeline.offsetOf(sessions, 1), 60000);
    expect(AudioTimeline.offsetOf(sessions, 2), 90000);
    expect(AudioTimeline.offsetOf(sessions, 99), 100000);
  });
}
