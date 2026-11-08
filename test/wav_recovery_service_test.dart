import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raven/services/wav_recovery_service.dart';

void main() {
  late Directory directory;
  late WavRecoveryService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('raven-wav-recovery-');
    service = WavRecoveryService();
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('repairs an interrupted PCM16 WAV header and measures its duration',
      () async {
    final file = File('${directory.path}\\interrupted.wav');
    await file.writeAsBytes(List<int>.filled(44 + 8000, 0));

    final durationMs = await service.repairPcm16File(
      file,
      sampleRate: 8000,
    );

    final bytes = await file.readAsBytes();
    expect(durationMs, 500);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');
    expect(bytes.length, 8044);
  });

  test('does not claim a take with no PCM frames is recoverable', () async {
    final file = File('${directory.path}\\empty.wav');
    await file.writeAsBytes(List<int>.filled(44, 0));

    expect(
      await service.repairPcm16File(file, sampleRate: 44100),
      isNull,
    );
  });
}
