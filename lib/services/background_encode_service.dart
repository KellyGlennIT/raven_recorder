import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/raven_project.dart';
import 'audio_merge_service.dart';
import 'project_repository.dart';

/// Runs slow audio transcodes (WAV capture → M4A / MP3 / FLAC) outside the
/// recording screen so the app is usable the instant a recording is saved.
///
/// How it works:
///
/// 1. The recorder commits the captured WAV file immediately as the session's
///    real audio (fully playable, shareable, resumable) and hands the transcode
///    to this service instead of blocking behind a dialog.
/// 2. Jobs run strictly one at a time, in the order queued, so a second
///    recording saved while the first is still encoding queues up cleanly.
/// 3. While a job runs, its progress in `[0.0, 1.0]` is published through
///    [progressByJob], keyed by `<projectId>/<sessionId>`. UI can show a
///    percentage chip on the library tile.
/// 4. When a job finishes, the encoded file replaces the session's
///    `audioPath`/`format` in the project record and the capture WAV is
///    deleted. [onProjectUpdated] lets the shell refresh the library.
///
/// Safety rules:
/// - Every job re-reads the project record from the repository right before
///   it acts and again right before it commits, so it merges its swap onto
///   the freshest state instead of clobbering newer edits.
/// - The WAV capture file remains the session's `audioPath` for the entire
///   duration of the encode, so playback and trimming work normally the whole
///   time. Only the final atomic swap replaces it.
/// - If the take was renamed on disk while queued, the job encodes from the
///   renamed path. If the take was REPLACED (resume-merge, amplify-commit)
///   the stale capture file is removed and the job aborts without touching
///   the replacement.
/// - If FFmpeg fails, nothing is swapped: the original WAV stays referenced
///   and playable, and [onError] explains what happened.
class BackgroundEncodeService {
  BackgroundEncodeService._();
  static final BackgroundEncodeService instance = BackgroundEncodeService._();

  final AudioMergeService _merge = AudioMergeService();
  final List<_EncodeJob> _queue = <_EncodeJob>[];
  bool _running = false;

  /// Jobs queued or running — observable for UI badges.
  final ValueNotifier<int> pendingJobs = ValueNotifier<int>(0);

  /// Per-job progress in [0.0, 1.0], keyed by `<projectId>/<sessionId>`.
  /// Entries are added when a job starts and removed when it finishes, fails,
  /// or is cancelled.
  final ValueNotifier<Map<String, double>> progressByJob =
      ValueNotifier<Map<String, double>>(<String, double>{});

  /// Called after a job rewrote a project record, so the shell can refresh.
  void Function(RavenProject project)? onProjectUpdated;

  /// Called when a job finishes successfully (user-facing message).
  void Function(String message)? onSuccess;

  /// Called when a job fails. The original recording always stays on disk
  /// and referenced, so a failure never loses audio.
  void Function(String message)? onError;

  bool get isBusy => _running || _queue.isNotEmpty;

  /// Progress of a specific job in [0.0, 1.0], or null when that job isn't
  /// running or queued.
  double? progressFor(String projectId, String sessionId) =>
      progressByJob.value[_key(projectId, sessionId)];

  /// Whether a specific session has an encode queued or running.
  bool isEncoding(String projectId, String sessionId) =>
      _isQueuedOrRunning(projectId, sessionId);

  // --- Shared mutex ----------------------------------------------------------
  // Serializes background encodes AND other file-rewriting services (audio
  // trimming) so two writers never touch the same session paths at once.
  Completer<void>? _mutexTail;

  /// Waits until every previously-acquired critical section has finished.
  /// Always pair with [releaseMutex] in a `finally`.
  Future<void> acquireMutex() async {
    final tail = _mutexTail?.future;
    final gate = Completer<void>();
    _mutexTail = gate;
    if (tail != null) await tail;
  }

  /// Marks the critical section started by the last [acquireMutex] as done.
  void releaseMutex() {
    final gate = _mutexTail;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  /// Convenience: runs [action] inside the shared mutex.
  Future<T> withMutex<T>(Future<T> Function() action) async {
    await acquireMutex();
    try {
      return await action();
    } finally {
      releaseMutex();
    }
  }

  String _key(String projectId, String sessionId) => '$projectId/$sessionId';

  bool _isQueuedOrRunning(String projectId, String sessionId) {
    final key = _key(projectId, sessionId);
    if (_queue.any((job) => _key(job.projectId, job.sessionId) == key)) {
      return true;
    }
    return _running && _currentKey == key;
  }

  String? _currentKey;
  String? _currentProjectId;

  /// Completes once no encode job for [projectId] is queued or running.
  Future<void> waitForProject(String projectId) async {
    while (_queue.any((job) => job.projectId == projectId) ||
        (_running && _currentProjectId == projectId)) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

  /// Queues converting the session [sessionId] of [project] from its capture
  /// file at [inputPath] into [targetFormat] (`m4a` | `mp3` | `flac`).
  /// Duplicate requests for the same session are ignored.
  void enqueueSessionConversion({
    required ProjectRepository repository,
    required RavenProject project,
    required String sessionId,
    required String inputPath,
    required String targetFormat,
    required int bitRate,
    required int sampleRate,
  }) {
    final format = targetFormat.toLowerCase();
    if (format == 'wav') return;
    if (_isQueuedOrRunning(project.id, sessionId)) return;

    _queue.add(_EncodeJob(
      repository: repository,
      projectId: project.id,
      sessionId: sessionId,
      inputPath: inputPath,
      targetFormat: format,
      bitRate: bitRate,
      sampleRate: sampleRate,
      label: project.title,
    ));
    pendingJobs.value = _queue.length + (_running ? 1 : 0);
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    await acquireMutex();
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeAt(0);
        _currentKey = _key(job.projectId, job.sessionId);
        _currentProjectId = job.projectId;
        pendingJobs.value = _queue.length + 1;
        _updateProgress(job, 0.0);
        try {
          await _run(job);
        } catch (error) {
          onError?.call(
            'Background encoding of "${job.label}" failed: $error. '
            'The recording was kept in its original format and stays playable.',
          );
        }
        _clearProgress(job);
        _currentKey = null;
        _currentProjectId = null;
        pendingJobs.value = _queue.length;
      }
    } finally {
      _running = false;
      pendingJobs.value = _queue.length;
      releaseMutex();
    }
  }

  void _updateProgress(_EncodeJob job, double value) {
    final key = _key(job.projectId, job.sessionId);
    final next = Map<String, double>.from(progressByJob.value);
    next[key] = value.clamp(0.0, 1.0).toDouble();
    progressByJob.value = next;
  }

  void _clearProgress(_EncodeJob job) {
    final key = _key(job.projectId, job.sessionId);
    if (!progressByJob.value.containsKey(key)) return;
    final next = Map<String, double>.from(progressByJob.value)..remove(key);
    progressByJob.value = next;
  }

  Future<void> _run(_EncodeJob job) async {
    final project = job.repository.projectById(job.projectId);
    if (project == null) {
      await _deleteQuietly(job.inputPath);
      return;
    }
    RavenAudioSession? session;
    for (final s in project.sessions) {
      if (s.id == job.sessionId) session = s;
    }
    if (session == null) {
      await _deleteQuietly(job.inputPath);
      return;
    }

    // The record moved ahead of the queued input path. Distinguish a rename
    // (the capture file was moved, so its old path no longer exists) from a
    // replacement (resume-merge / amplify committed a different file).
    var inputPath = job.inputPath;
    if (session.audioPath != inputPath) {
      if (session.audioPath.endsWith('.ravenenc')) {
        // The user encrypted the project while this job waited.
        return;
      }
      final originalStillExists = await File(inputPath).exists();
      if (originalStillExists) {
        await _deleteQuietly(inputPath);
        return;
      }
      final renamed = File(session.audioPath);
      if (!await renamed.exists()) {
        onError?.call(
          'Background encoding of "${job.label}" could not start because the '
          'captured audio file disappeared.',
        );
        return;
      }
      inputPath = session.audioPath;
    }

    final input = File(inputPath);
    if (!await input.exists()) {
      onError?.call(
        'Background encoding of "${job.label}" could not start because the '
        'captured audio file disappeared.',
      );
      return;
    }

    final directory = input.parent;
    final baseName = job.repository.projectFolderName(project);
    final targetPath =
        '${directory.path}/$baseName-${job.sessionId}.${job.targetFormat}';

    final totalMs = session.durationMs > 0 ? session.durationMs : 0;

    final encoded = await _merge.convertToFormatAsync(
      input: input,
      outputPath: targetPath,
      format: job.targetFormat,
      bitRate: job.bitRate,
      sampleRate: job.sampleRate,
      estimatedDuration:
          totalMs > 0 ? Duration(milliseconds: totalMs) : null,
      onProgress: (p) => _updateProgress(job, p),
    );

    // Re-read immediately before committing: the user may have edited the
    // project (rename, bookmarks, notes) during the encode. Rebase the swap
    // onto the freshest record instead of overwriting it.
    final latest = job.repository.projectById(job.projectId);
    if (latest == null) {
      await _deleteQuietly(encoded.path);
      await _deleteQuietly(inputPath);
      return;
    }
    RavenAudioSession? latestSession;
    for (final s in latest.sessions) {
      if (s.id == job.sessionId) latestSession = s;
    }
    if (latestSession == null || latestSession.audioPath != inputPath) {
      // The take was replaced or the file moved during the encode.
      await _deleteQuietly(encoded.path);
      return;
    }

    final updatedSession = latestSession.copyWith(
      audioPath: encoded.path,
      format: job.targetFormat,
      recoverablePcm16: false,
    );
    final sessions = latest.sessions
        .map((s) => s.id == latestSession!.id ? updatedSession : s)
        .toList();
    final updated = latest.copyWith(
      sessions: sessions,
      updatedAt: DateTime.now(),
      clearMasterAudioPath: true,
    );
    await job.repository.update(updated);
    onProjectUpdated?.call(updated);

    await _deleteQuietly(inputPath);
    onSuccess?.call(
      '"${job.label}" finished encoding to ${job.targetFormat.toUpperCase()}.',
    );
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Best-effort; leftover capture files can be cleared later.
    }
  }

  /// Cancel the currently running encode, clear the queue, and reset progress.
  /// Safe to call at any time. The running session's WAV file remains the
  /// session's `audioPath`, so nothing is lost.
  Future<void> cancelAll() async {
    _queue.clear();
    progressByJob.value = <String, double>{};
    pendingJobs.value = 0;
    await _merge.cancelActiveSession();
  }
}

class _EncodeJob {
  _EncodeJob({
    required this.repository,
    required this.projectId,
    required this.sessionId,
    required this.inputPath,
    required this.targetFormat,
    required this.bitRate,
    required this.sampleRate,
    required this.label,
  });

  final ProjectRepository repository;
  final String projectId;
  final String sessionId;
  final String inputPath;
  final String targetFormat;
  final int bitRate;
  final int sampleRate;
  final String label;
}