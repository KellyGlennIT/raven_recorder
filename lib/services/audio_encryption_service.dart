import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

class AudioPasswordException implements Exception {
  final String message;
  const AudioPasswordException(
      [this.message = 'The audio password is incorrect.']);

  @override
  String toString() => message;
}

/// Experimental authenticated AES-256-GCM file encryption for RAVEN projects.
/// Current implementation buffers whole files in memory; do not rely on it for
/// large or irreplaceable recordings. The service fails closed: ciphertext is
/// never silently treated as playable audio.
class AudioEncryptionService {
  AudioEncryptionService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final AesGcm _algorithm = AesGcm.with256bits();
  static const String _legacyKeyName = 'raven.audioEncryptionKey.v1';
  static const List<int> _legacyMagic = <int>[
    82,
    65,
    86,
    69,
    78,
    69,
    78,
    67,
    49
  ];
  static const List<int> _passwordMagic = <int>[
    82,
    65,
    86,
    69,
    78,
    69,
    78,
    67,
    50
  ];
  static const int _nonceLength = 12;
  static const int _macLength = 16;
  static const int _saltLength = 16;
  static const int _passwordIterations = 210000;

  String createProtectionSalt() {
    final random = Random.secure();
    return base64Encode(
        List<int>.generate(_saltLength, (_) => random.nextInt(256)));
  }

  Future<SecretKey> derivePasswordKey(
      String password, String encodedSalt) async {
    final salt = base64Decode(encodedSalt);
    if (salt.length != _saltLength) {
      throw const FormatException('Invalid RAVEN audio-protection salt.');
    }
    return Pbkdf2.hmacSha256(
      iterations: _passwordIterations,
      bits: 256,
    ).deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  Future<SecretKey> _readExistingKey() async {
    final encoded = await _storage.read(key: _legacyKeyName);
    if (encoded == null) {
      throw StateError(
          'RAVEN encryption key is missing. Protected audio cannot be decrypted.');
    }
    final bytes = base64Decode(encoded);
    if (bytes.length != 32) {
      throw const FormatException('Invalid RAVEN encryption key.');
    }
    return SecretKey(bytes);
  }

  /// Remove abandoned plaintext playback caches from a previous app process.
  /// Call once during startup before any player is opened; never call while playback is active.
  static Future<void> cleanupAbandonedPlaybackFiles() async {
    final temporaryDirectory = await getTemporaryDirectory();
    if (!await temporaryDirectory.exists()) return;
    await for (final entity in temporaryDirectory.list(followLinks: false)) {
      if (entity is! File ||
          !entity.uri.pathSegments.last.startsWith('raven-playback-')) {
        continue;
      }
      try {
        await entity.delete();
      } on FileSystemException {
        // A cache may be locked by the OS; cleanup is best-effort and must not block launch.
      }
    }
  }

  Future<void> encryptFile({
    required File input,
    required File output,
    required SecretKey key,
    void Function(double progress)? onProgress,
  }) async {
    if (!await input.exists()) {
      throw FileSystemException('Audio file does not exist.', input.path);
    }
    if (input.absolute.path == output.absolute.path) {
      throw ArgumentError('Input and output must be different files.');
    }
    final totalBytes = await input.length();
    final chunks = <int>[];
    final inputStream = input.openRead();
    await for (final chunk in inputStream) {
      chunks.addAll(chunk);
      if (totalBytes > 0) {
        onProgress?.call((chunks.length / totalBytes).clamp(0.0, 0.9));
      }
    }
    final clearBytes = Uint8List.fromList(chunks);
    final nonce =
        List<int>.generate(_nonceLength, (_) => Random.secure().nextInt(256));
    final box =
        await _algorithm.encrypt(clearBytes, secretKey: key, nonce: nonce);
    await output.parent.create(recursive: true);
    final temporary = File('${output.path}.tmp');
    try {
      await temporary.writeAsBytes(<int>[
        ..._passwordMagic,
        ...box.nonce,
        ...box.mac.bytes,
        ...box.cipherText
      ], flush: true);
      if (await output.exists()) await output.delete();
      await temporary.rename(output.path);
      onProgress?.call(1.0);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> decryptFile({
    required File input,
    required File output,
    SecretKey? key,
    void Function(double progress)? onProgress,
  }) async {
    final bytes = await input.readAsBytes();
    final isLegacy = _startsWith(bytes, _legacyMagic);
    final isPasswordProtected = _startsWith(bytes, _passwordMagic);
    if (!isLegacy && !isPasswordProtected) {
      throw const FormatException(
          'This file is not a RAVEN-encrypted audio file.');
    }
    final magic = isLegacy ? _legacyMagic : _passwordMagic;
    final headerLength = magic.length + _nonceLength + _macLength;
    if (bytes.length < headerLength) {
      throw const FormatException(
          'The RAVEN-encrypted audio file is incomplete.');
    }
    final nonceStart = magic.length;
    final macStart = nonceStart + _nonceLength;
    final cipherStart = macStart + _macLength;
    final box = SecretBox(
      bytes.sublist(cipherStart),
      nonce: bytes.sublist(nonceStart, macStart),
      mac: Mac(bytes.sublist(macStart, cipherStart)),
    );
    // Authentication failure throws; no unauthenticated plaintext is written.
    final decryptionKey = isLegacy ? await _readExistingKey() : key;
    if (decryptionKey == null) {
      throw StateError('Enter the audio password to unlock this recording.');
    }
    onProgress?.call(0.5);
    late final List<int> clear;
    try {
      clear = await _algorithm.decrypt(box, secretKey: decryptionKey);
    } on SecretBoxAuthenticationError {
      if (!isLegacy) throw const AudioPasswordException();
      throw StateError('The protected audio could not be authenticated.');
    }
    await output.parent.create(recursive: true);
    final temporary = File('${output.path}.tmp');
    try {
      await temporary.writeAsBytes(Uint8List.fromList(clear), flush: true);
      if (await output.exists()) await output.delete();
      await temporary.rename(output.path);
      onProgress?.call(1.0);
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
