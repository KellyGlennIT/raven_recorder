import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores user-provided AI credentials in the operating system's secure store.
/// Never write API keys into project JSON, logs, exports, or shared preferences.
class AiKeyVault {
  AiKeyVault({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const String _prefix = 'raven.aiKey.';

  String _keyFor(String provider) {
    final normalized = provider.trim().toLowerCase();
    if (normalized.isEmpty || !RegExp(r'^[a-z0-9._-]{1,48}$').hasMatch(normalized)) {
      throw ArgumentError.value(provider, 'provider', 'Use a short provider identifier.');
    }
    return '$_prefix$normalized';
  }

  Future<void> saveKey(String provider, String apiKey) async {
    final value = apiKey.trim();
    if (value.isEmpty) throw ArgumentError('API key cannot be empty.');
    await _storage.write(key: _keyFor(provider), value: value);
  }

  Future<String?> readKey(String provider) => _storage.read(key: _keyFor(provider));

  Future<void> deleteKey(String provider) => _storage.delete(key: _keyFor(provider));

  Future<bool> hasKey(String provider) async => (await readKey(provider))?.isNotEmpty ?? false;
}
