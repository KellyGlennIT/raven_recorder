import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raven/services/audio_encryption_service.dart';

void main() {
  test('password-protected audio decrypts with its password only', () async {
    final directory = await Directory.systemTemp.createTemp('raven-audio-');
    addTearDown(() => directory.delete(recursive: true));
    final original = File('${directory.path}/source.wav');
    final encrypted = File('${directory.path}/source.wav.ravenenc');
    final decrypted = File('${directory.path}/decrypted.wav');
    final encryption = AudioEncryptionService();
    final password = 'correct horse battery';
    final salt = encryption.createProtectionSalt();
    final key = await encryption.derivePasswordKey(password, salt);
    final originalBytes = List<int>.generate(256, (index) => index);
    await original.writeAsBytes(originalBytes);

    await encryption.encryptFile(
      input: original,
      output: encrypted,
      key: key,
    );
    expect(await encrypted.readAsBytes(), isNot(originalBytes));
    await encryption.decryptFile(input: encrypted, output: decrypted, key: key);
    expect(await decrypted.readAsBytes(), originalBytes);

    final incorrectKey =
        await encryption.derivePasswordKey('wrong password', salt);
    await expectLater(
      encryption.decryptFile(
        input: encrypted,
        output: File('${directory.path}/wrong.wav'),
        key: incorrectKey,
      ),
      throwsA(isA<AudioPasswordException>()),
    );
    expect(await File('${directory.path}/wrong.wav').exists(), isFalse);
  });
}
