import '../models/raven_project.dart';

/// Maps internal recording sessions onto the single user-facing project timeline.
/// Sessions stay as separate source files so a later continuation never has to
/// rewrite or re-encode the existing master audio.
class AudioTimeline {
  const AudioTimeline._();

  static int totalDurationMs(List<RavenAudioSession> sessions) =>
      sessions.fold<int>(0, (total, session) => total + session.durationMs);

  static int offsetOf(List<RavenAudioSession> sessions, int index) {
    var offset = 0;
    final end = index.clamp(0, sessions.length).toInt();
    for (var i = 0; i < end; i++) {
      offset += sessions[i].durationMs;
    }
    return offset;
  }

  /// Returns (session index, offset within that session) for a global position.
  /// A position exactly on a boundary belongs to the following session, except
  /// for the final end position, which belongs to the last session.
  static ({int index, int localMs}) locate(
    List<RavenAudioSession> sessions,
    int globalMs,
  ) {
    if (sessions.isEmpty) return (index: 0, localMs: 0);
    var remaining = globalMs.clamp(0, totalDurationMs(sessions)).toInt();
    for (var i = 0; i < sessions.length; i++) {
      final length = sessions[i].durationMs;
      if (remaining < length || i == sessions.length - 1) {
        return (index: i, localMs: remaining.clamp(0, length).toInt());
      }
      remaining -= length;
    }
    final last = sessions.length - 1;
    return (index: last, localMs: sessions[last].durationMs);
  }
}
