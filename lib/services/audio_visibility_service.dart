import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Manages an optional public copy separately from RAVEN's private source.
/// Android uses MediaStore; Windows uses the user's Downloads/RAVEN folder.
class AudioVisibilityService {
  static const MethodChannel _channel = MethodChannel('raven/audio_visibility');

  /// True when [location] is an Android MediaStore-style `content://` URI
  /// (returned by [publish] / [publishFolder] via the native channel), rather
  /// than a real filesystem path.
  ///
  /// Callers that need to inspect, move, or delete a folder should route
  /// content:// URIs through [removeFolder] / [remove] instead of `Directory`
  /// or `File`. Real filesystem paths continue to use normal dart:io APIs.
  static bool isContentUri(String location) =>
      location.startsWith('content://');

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

  /// Publishes a whole project folder (audio + notes + attachments) into the
  /// device's public RAVEN folder so it can be browsed with a file manager.
  /// Returns the public folder location.
  Future<String> publishFolder({
    required Directory source,
    required String folderName,
  }) async {
    if (!await source.exists()) {
      throw FileSystemException('The project folder does not exist.', source.path);
    }
    final safeFolder = _safeName(folderName);
    if (Platform.isAndroid) {
      final location = await _channel.invokeMethod<String>(
        'publishFolder',
        <String, Object?>{
          'sourcePath': source.path,
          'folderName': safeFolder,
        },
      );
      if (location == null || location.isEmpty) {
        throw StateError('Android did not return the published folder URI.');
      }
      return location;
    }
    if (Platform.isWindows) {
      final downloads = await getDownloadsDirectory();
      if (downloads == null) {
        throw StateError('Windows Downloads folder could not be located.');
      }
      final destination = Directory(
          '${downloads.path}${Platform.pathSeparator}RAVEN${Platform.pathSeparator}$safeFolder');
      if (await destination.exists()) {
        await destination.delete(recursive: true);
      }
      await destination.create(recursive: true);
      await for (final entity in source.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = entity.path.substring(source.path.length + 1);
        final target = File('${destination.path}${Platform.pathSeparator}$relative');
        await target.parent.create(recursive: true);
        await entity.copy(target.path);
      }
      return destination.path;
    }
    throw UnsupportedError(
        'Public project folders are currently supported on Android and Windows.');
  }

  Future<void> removeFolder(String location) async {
    if (location.startsWith('content://') && Platform.isAndroid) {
      final removed = await _channel.invokeMethod<bool>(
        'deletePublishedFolder',
        <String, Object?>{'uri': location},
      );
      if (removed != true) {
        throw StateError('RAVEN could not confirm removal of the public folder.');
      }
      return;
    }
    if (Platform.isWindows) {
      final directory = Directory(location);
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    }
    throw UnsupportedError(
        'Removing public project folders is currently supported on Android and Windows.');
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