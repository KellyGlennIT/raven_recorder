import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Manages an optional public copy separately from RAVEN's private source.
/// Android uses MediaStore; Windows uses the user's Downloads/RAVEN folder.
class AudioVisibilityService {
  static const MethodChannel _channel = MethodChannel('raven/audio_visibility');

  Future<String> publish({required File source, required String title, required String projectId}) async {
    if (!await source.exists()) throw FileSystemException('The source audio does not exist.', source.path);
    final leaf = source.uri.pathSegments.isEmpty ? source.path : source.uri.pathSegments.last;
    final extension = leaf.contains('.') ? leaf.split('.').last.toLowerCase() : 'm4a';
    final safeTitle = _safeName(title);
    final fileName = '$safeTitle-$projectId.$extension';
    final mimeType = switch (extension) {
      'wav' => 'audio/wav',
      'flac' => 'audio/flac',
      'mp3' => 'audio/mpeg',
      _ => 'audio/mp4',
    };

    if (Platform.isAndroid) {
      final location = await _channel.invokeMethod<String>('publishAudio', <String, Object?>{
        'sourcePath': source.path,
        'fileName': fileName,
        'mimeType': mimeType,
      });
      if (location == null || location.isEmpty) throw StateError('Android did not return the published audio URI.');
      return location;
    }
    if (Platform.isWindows) {
      final downloads = await getDownloadsDirectory();
      if (downloads == null) throw StateError('Windows Downloads folder could not be located.');
      final directory = Directory('${downloads.path}${Platform.pathSeparator}RAVEN');
      await directory.create(recursive: true);
      final destination = File('${directory.path}${Platform.pathSeparator}$fileName');
      await source.copy(destination.path);
      if (await destination.length() != await source.length()) {
        try { await destination.delete(); } catch (_) {}
        throw StateError('The public audio copy failed verification.');
      }
      return destination.path;
    }
    throw UnsupportedError('Public-folder visibility is currently supported on Android and Windows.');
  }

  Future<void> remove(String location) async {
    if (location.startsWith('content://') && Platform.isAndroid) {
      final removed = await _channel.invokeMethod<bool>(
        'deletePublishedAudio',
        <String, Object?>{'uri': location},
      );
      if (removed != true) {
        throw StateError('RAVEN could not confirm removal of the public audio copy.');
      }
      return;
    }
    if (Platform.isWindows) {
      final file = File(location);
      if (await file.exists()) await file.delete();
      return;
    }
    throw UnsupportedError('Removing managed public copies is currently supported on Android and Windows.');
  }

  String _safeName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return 'RAVEN recording';
    return cleaned.length > 70 ? cleaned.substring(0, 70).trim() : cleaned;
  }
}
