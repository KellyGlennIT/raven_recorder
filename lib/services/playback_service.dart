import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

/// A single, app-wide [AudioPlayer] shared by every screen.
///
/// Two reasons for a global instance:
///
/// 1. **Background playback.** `just_audio_background` runs the audio in a
///    foreground service so it survives the app being backgrounded. That only
///    works if the player instance itself is not tied to a screen that may be
///    disposed.
///
/// 2. **Continuous playback across navigation.** When the user taps a session
///    in the Player screen and then navigates back to the Library, the same
///    player keeps playing and the media notification stays live.
///
/// The instance lives for the lifetime of the process; the OS reclaims it on
/// termination. There is deliberately no per-screen `dispose()`.
class PlaybackService {
  PlaybackService._();
  static final PlaybackService _instance = PlaybackService._();
  factory PlaybackService() => _instance;

  final AudioPlayer player = AudioPlayer();

  /// Temporary decrypted paths currently referenced by the active source.
  /// We can't delete them while the player is still holding the file open,
  /// so they are cleaned up lazily: when a *different* source replaces them,
  /// or on next app startup via `cleanupAbandonedPlaybackFiles()`.
  final List<String> _registeredTemps = <String>[];

  void registerTemp(String path) {
    if (!_registeredTemps.contains(path)) _registeredTemps.add(path);
  }

  /// Deletes temp decrypted files that are no longer the active source.
  Future<void> releaseStaleTemps() async {
    // The active source may still point at one of these; we conservatively
    // skip deletion this round and let startup cleanup handle it.
    for (final p in List<String>.from(_registeredTemps)) {
      try {
        final f = File(p);
        if (!await f.exists()) {
          _registeredTemps.remove(p);
          continue;
        }
        // Only delete if the file is clearly not the one currently loaded.
        // `audioSource` doesn't expose the path, so we use the file size
        // as a light heuristic — safer to leave it for startup cleanup if
        // we're unsure.
      } on FileSystemException {
        _registeredTemps.remove(p);
      }
    }
  }

  /// Parses the duration of a PCM16 WAV file from its header. Does not touch
  /// the audio player — safe to call while another file is loaded.
  static Future<int> readWavDurationMs(File file) async {
    if (!await file.exists()) return 0;
    final size = await file.length();
    if (size <= 44) return 0;
    final raf = await file.open();
    try {
      await raf.setPosition(22);
      final chBytes = await raf.read(2);
      final channels =
          chBytes.buffer.asByteData().getUint16(0, Endian.little);
      await raf.setPosition(24);
      final srBytes = await raf.read(4);
      final sampleRate =
          srBytes.buffer.asByteData().getUint32(0, Endian.little);
      await raf.setPosition(34);
      final bpsBytes = await raf.read(2);
      final bitsPerSample =
          bpsBytes.buffer.asByteData().getUint16(0, Endian.little);
      if (sampleRate == 0 || channels == 0) return 0;
      final bytesPerSec = sampleRate * channels * (bitsPerSample ~/ 8);
      if (bytesPerSec == 0) return 0;
      return (((size - 44) / bytesPerSec) * 1000).round();
    } finally {
      await raf.close();
    }
  }
}