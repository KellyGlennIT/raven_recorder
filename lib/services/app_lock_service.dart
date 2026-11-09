import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// PIN verifier for the in-app privacy gate. The PIN itself is never persisted.
/// This is an app-access barrier, not full-disk/file encryption.
class AppLockService {
  AppLockService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _saltKey = 'raven.appLock.salt.v1';
  static const _verifierKey = 'raven.appLock.verifier.v1';
  static const _iterations = 120000;

  static bool isValidPin(String pin) => RegExp(r'^\d{4,12}$').hasMatch(pin);

  Future<bool> get hasPin async =>
      await _storage.read(key: _saltKey) != null &&
      await _storage.read(key: _verifierKey) != null;

  Future<void> setPin(String pin) async {
    if (!isValidPin(pin)) {
      throw ArgumentError('Use a PIN containing 4 to 12 digits.');
    }
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final key = await _derive(pin, salt);
    await _storage.write(key: _saltKey, value: base64Encode(salt));
    await _storage.write(key: _verifierKey, value: base64Encode(key));
  }

  Future<bool> verifyPin(String pin) async {
    final encodedSalt = await _storage.read(key: _saltKey);
    final encodedVerifier = await _storage.read(key: _verifierKey);
    if (encodedSalt == null || encodedVerifier == null) return false;
    try {
      final candidate = await _derive(pin, base64Decode(encodedSalt));
      final expected = base64Decode(encodedVerifier);
      if (candidate.length != expected.length) return false;
      var difference = 0;
      for (var i = 0; i < candidate.length; i++) {
        difference |= candidate[i] ^ expected[i];
      }
      return difference == 0;
    } on FormatException {
      return false;
    }
  }

  Future<void> removePin() async {
    await _storage.delete(key: _saltKey);
    await _storage.delete(key: _verifierKey);
  }

  Future<List<int>> _derive(String pin, List<int> salt) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _iterations,
      bits: 256,
    );
    final secret = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return secret.extractBytes();
  }
}
