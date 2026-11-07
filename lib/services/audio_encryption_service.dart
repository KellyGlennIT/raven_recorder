import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Experimental authenticated AES-256-GCM file encryption for RAVEN projects.
/// Current implementation buffers whole files in memory; do not rely on it for
/// large or irreplaceable recordings. The service fails closed: ciphertext is
/// never silently treated as playable audio.
class AudioEncryptionService {
  AudioEncryptionService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final AesGcm _algorithm = AesGcm.with256bits();
  static const String _keyName = 'raven.audioEncryptionKey.v1';
  static const List<int> _magic = <int>[82, 65, 86, 69, 78, 69, 78, 67, 49]; // RAVENENC1
  static const int _nonceLength = 12;
  static const int _macLength = 16;

  Future<SecretKey> _getOrCreateKey() async {
    final encoded = await _storage.read(key: _keyName);
    if (encoded != null) {
      final bytes = base64Decode(encoded);
      if (bytes.length != 32) throw const FormatException('Invalid RAVEN encryption key.');
      return SecretKey(bytes);
    }
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    await _storage.write(key: _keyName, value: base64Encode(bytes));
    return SecretKey(bytes);
  }

  Future<SecretKey> _readExistingKey() async {
    final encoded = await _storage.read(key: _keyName);
    if (encoded == null) {
      throw StateError('RAVEN encryption key is missing. Protected audio cannot be decrypted.');
    }
    final bytes = base64Decode(encoded);
    if (bytes.length != 32) throw const FormatException('Invalid RAVEN encryption key.');
    return SecretKey(bytes);
  }

  /// Remove abandoned plaintext playback caches from a previous app process.
  /// Call once during startup before any player is opened; never call while playback is active.
  static Future<void> cleanupAbandonedPlaybackFiles() async {
    final temporaryDirectory = await getTemporaryDirectory();
    if (!await temporaryDirectory.exists()) return;
    await for (final entity in temporaryDirectory.list(followLinks: false)) {
      if (entity is! File || !entity.uri.pathSegments.last.startsWith('raven-playback-')) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        // A cache may be locked by the OS; cleanup is best-effort and must not block launch.
      }
    }
  }

  Future<void> encryptFile({required File input, required File output}) async {
    if (!await input.exists()) throw FileSystemException('Audio file does not exist.', input.path);
    if (input.absolute.path == output.absolute.path) {
      throw ArgumentError('Input and output must be different files.');
    }
    final clearBytes = await input.readAsBytes();
    final nonce = List<int>.generate(_nonceLength, (_) => Random.secure().nextInt(256));
    final box = await _algorithm.encrypt(clearBytes, secretKey: await _getOrCreateKey(), nonce: nonce);
    await output.parent.create(recursive: true);
    final temporary = File('${output.path}.tmp');
    try {
      await temporary.writeAsBytes(<int>[..._magic, ...box.nonce, ...box.mac.bytes, ...box.cipherText], flush: true);
      if (await output.exists()) await output.delete();
      await temporary.rename(output.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> decryptFile({required File input, required File output}) async {
    final bytes = await input.readAsBytes();
    final headerLength = _magic.length + _nonceLength + _macLength;
    if (bytes.length < headerLength || !_startsWith(bytes, _magic)) {
      throw const FormatException('This file is not a RAVEN-encrypted audio file.');
    }
    final nonceStart = _magic.length;
    final macStart = nonceStart + _nonceLength;
    final cipherStart = macStart + _macLength;
    final box = SecretBox(
      bytes.sublist(cipherStart),
      nonce: bytes.sublist(nonceStart, macStart),
      mac: Mac(bytes.sublist(macStart, cipherStart)),
    );
    // Authentication failure throws; no unauthenticated plaintext is written.
    final clear = await _algorithm.decrypt(box, secretKey: await _readExistingKey());
    await output.parent.create(recursive: true);
    final temporary = File('${output.path}.tmp');
    try {
      await temporary.writeAsBytes(Uint8List.fromList(clear), flush: true);
      if (await output.exists()) await output.delete();
      await temporary.rename(output.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  bool _startsWith(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }
}
