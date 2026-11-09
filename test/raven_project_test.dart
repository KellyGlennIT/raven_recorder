import 'package:flutter_test/flutter_test.dart';
import 'package:raven/models/raven_project.dart';
import 'package:raven/services/scheduled_recording_service.dart';
import 'package:raven/services/app_preferences.dart';
import 'package:raven/services/project_repository.dart';

void main() {
  test('recording format options include MP3 export', () {
    expect(AppPreferences.supportedRecordingFormats, contains('mp3'));
  });

  group('ScheduledRecording persistence model', () {
    test('serializes and restores the requested local date and title', () {
      final schedule = ScheduledRecording(
        id: 'schedule-1',
        title: 'Morning voice note',
        scheduledAt: DateTime(2026, 11, 3, 7, 15),
      );
      final restored = ScheduledRecording.fromJson(
        Map<String, Object?>.from(schedule.toJson()),
      );
      expect(restored.id, schedule.id);
      expect(restored.title, schedule.title);
      expect(restored.scheduledAt, schedule.scheduledAt);
    });
  });

  group('RavenProject persistence model', () {
    test('serializes and restores a project without changing its stable ID',
        () {
      final createdAt = DateTime.utc(2026, 10, 28, 8, 30);
      final project = RavenProject(
        id: 'project-id-123',
        title: 'Sermon idea',
        createdAt: createdAt,
        updatedAt: createdAt,
        category: 'Uncategorized',
        sessions: <RavenAudioSession>[
          RavenAudioSession(
            id: 'session-id-123',
            audioPath:
                '/private/raven/projects/project-id-123/sessions/session-id-123.m4a',
            createdAt: createdAt,
            durationMs: 42000,
            format: 'm4a',
          ),
        ],
        notes: 'Keep the opening exactly as recorded.',
        tags: const <String>['idea', 'sermon'],
        masterAudioPath:
            '/private/raven/projects/project-id-123/sessions/project-id-123.master.m4a',
        publicCopyLocation: 'content://media/external/audio/media/123',
      );

      final restored = RavenProject.fromJson(
        Map<String, Object?>.from(project.toJson()),
      );

      expect(restored.id, project.id);
      expect(restored.title, project.title);
      expect(restored.createdAt, project.createdAt);
      expect(restored.sessions.single.id, project.sessions.single.id);
      expect(restored.sessions.single.audioPath,
          project.sessions.single.audioPath);
      expect(restored.durationMs, 42000);
      expect(restored.notes, project.notes);
      expect(restored.tags, project.tags);
      expect(restored.masterAudioPath, project.masterAudioPath);
      expect(restored.latestAudioPath, project.masterAudioPath);
      expect(restored.publicCopyLocation, project.publicCopyLocation);
    });

    test('persists timeline bookmarks and new optional metadata', () {
      final now = DateTime.utc(2026, 10, 28, 9);
      final project = RavenProject(
        id: 'bookmark-project',
        title: 'Interview',
        createdAt: now,
        updatedAt: now,
        sessions: <RavenAudioSession>[
          RavenAudioSession(
            id: 'session-1',
            audioPath: '/tmp/session.m4a',
            createdAt: now,
            durationMs: 120000,
          ),
        ],
        bookmarks: <RavenBookmark>[
          RavenBookmark(
            id: 'mark-1',
            sessionId: 'session-1',
            positionMs: 15500,
            label: 'Important answer',
            createdAt: now,
          ),
        ],
        isAudioProtected: true,
        aiGeneratedContent: const <String, String>{
          'summary': 'Separate generated summary'
        },
      );
      final restored =
          RavenProject.fromJson(Map<String, Object?>.from(project.toJson()));
      expect(restored.bookmarks.single.positionMs, 15500);
      expect(restored.bookmarks.single.sessionId, 'session-1');
      expect(restored.isAudioProtected, isTrue);
      expect(
          restored.aiGeneratedContent['summary'], 'Separate generated summary');
    });

    test(
        'continuing a project appends a session without changing project identity or title',
        () {
      final now = DateTime.utc(2026, 10, 28, 9);
      final first = RavenAudioSession(
        id: 'session-first',
        audioPath: '/private/first.m4a',
        createdAt: now,
        durationMs: 60000,
      );
      final project = RavenProject(
        id: 'stable-project-id',
        title: 'Interview with John',
        createdAt: now,
        updatedAt: now,
        sessions: <RavenAudioSession>[first],
      );
      final second = RavenAudioSession(
        id: 'session-second',
        audioPath: '/private/second.m4a',
        createdAt: now.add(const Duration(days: 1)),
        durationMs: 30000,
      );
      final continued = project.copyWith(
        updatedAt: now.add(const Duration(days: 1)),
        sessions: <RavenAudioSession>[...project.sessions, second],
      );

      expect(continued.id, 'stable-project-id');
      expect(continued.title, 'Interview with John');
      expect(continued.sessions, hasLength(2));
      expect(continued.sessions.first.audioPath, first.audioPath);
      expect(continued.sessions.last.id, 'session-second');
      expect(continued.durationMs, 90000);
    });

    test('loads older project records with defaults for newly added fields',
        () {
      final now = DateTime.utc(2026, 10, 28);
      final restored = RavenProject.fromJson(<String, Object?>{
        'id': 'legacy',
        'title': 'Older project',
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'sessions': <Object?>[],
      });

      expect(restored.bookmarks, isEmpty);
      expect(restored.isAudioProtected, isFalse);
      expect(restored.aiGeneratedContent, isEmpty);
      expect(restored.masterAudioPath, isNull);
    });

    test('uses the last update as a safe trash date for legacy records', () {
      final updatedAt = DateTime.utc(2026, 11, 2, 10);
      final restored = RavenProject.fromJson(<String, Object?>{
        'id': 'legacy-trash',
        'title': 'Legacy item',
        'createdAt': DateTime.utc(2026, 11, 1).toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'sessions': <Object?>[],
        'isTrashed': true,
      });

      expect(restored.trashedAt, updatedAt);
    });

    test('loads older sessions with safe interrupted-recording defaults', () {
      final session = RavenAudioSession.fromJson(<String, Object?>{
        'id': 'legacy-session',
        'audioPath': 'legacy.m4a',
        'createdAt': DateTime.utc(2025).toIso8601String(),
        'durationMs': 1200,
      });

      expect(session.sampleRate, 44100);
      expect(session.recoverablePcm16, isFalse);
    });

    test('persists standalone recording identity across model copies', () {
      final now = DateTime.utc(2026, 10, 28);
      final recording = RavenProject(
        id: 'standalone-recording',
        title: 'Voice memo',
        createdAt: now,
        updatedAt: now,
        sessions: const <RavenAudioSession>[],
        isStandalone: true,
      );

      final restored = RavenProject.fromJson(
        Map<String, Object?>.from(recording.toJson()),
      );

      expect(restored.isStandalone, isTrue);
      expect(recording.copyWith(title: 'Renamed').isStandalone, isTrue);
    });

    test('persists the trash timestamp and clears it when restored', () {
      final now = DateTime.utc(2026, 11, 8, 12);
      final project = RavenProject(
        id: 'trashed-project',
        title: 'Archived interview',
        createdAt: now,
        updatedAt: now,
        sessions: const <RavenAudioSession>[],
        isTrashed: true,
        trashedAt: now,
      );
      final restored = RavenProject.fromJson(
        Map<String, Object?>.from(project.toJson()),
      );

      expect(restored.trashedAt, now);
      expect(
          restored.copyWith(isTrashed: false, clearTrashedAt: true).trashedAt,
          isNull);
    });

    test('trash expiry honors the configured retention boundary', () {
      final trashedAt = DateTime.utc(2026, 11, 1, 12);
      final project = RavenProject(
        id: 'expiry-check',
        title: 'Old recording',
        createdAt: trashedAt,
        updatedAt: trashedAt,
        sessions: const <RavenAudioSession>[],
        isTrashed: true,
        trashedAt: trashedAt,
      );
      expect(
        ProjectRepository.isTrashExpired(
          project,
          retentionDays: 7,
          now: trashedAt.add(const Duration(days: 6, hours: 23)),
        ),
        isFalse,
      );
      expect(
        ProjectRepository.isTrashExpired(
          project,
          retentionDays: 7,
          now: trashedAt.add(const Duration(days: 7)),
        ),
        isTrue,
      );
      expect(
        ProjectRepository.isTrashExpired(
          project,
          retentionDays: 0,
          now: trashedAt.add(const Duration(days: 365)),
        ),
        isFalse,
      );
    });

    test(
        'copying a project preserves identity and changes only requested fields',
        () {
      final now = DateTime.utc(2026, 10, 28);
      final project = RavenProject(
        id: 'stable-id',
        title: 'First title',
        createdAt: now,
        updatedAt: now,
        sessions: const <RavenAudioSession>[],
      );

      final renamed = project.copyWith(title: 'Renamed project');

      expect(renamed.id, project.id);
      expect(renamed.createdAt, project.createdAt);
      expect(renamed.title, 'Renamed project');
      expect(
          renamed.updatedAt.isAfter(project.updatedAt) ||
              renamed.updatedAt == project.updatedAt,
          isTrue);
    });

    test(
        'renaming never changes audio paths, session IDs, notes or master path',
        () {
      final now = DateTime.utc(2026, 10, 29, 10);
      final session = RavenAudioSession(
        id: 'session-stable',
        audioPath:
            '/private/raven/projects/project-stable/sessions/session-stable.m4a',
        createdAt: now,
        durationMs: 42000,
      );
      final project = RavenProject(
        id: 'project-stable',
        title: 'Before rename',
        createdAt: now,
        updatedAt: now,
        sessions: <RavenAudioSession>[session],
        notes: 'These notes stay attached.',
        masterAudioPath:
            '/private/raven/projects/project-stable/sessions/project-stable.master.m4a',
      );

      final renamed = project.copyWith(title: 'After rename');

      expect(renamed.id, project.id);
      expect(renamed.sessions.single.id, session.id);
      expect(renamed.sessions.single.audioPath, session.audioPath);
      expect(renamed.masterAudioPath, project.masterAudioPath);
      expect(renamed.notes, project.notes);
    });
  });
}
