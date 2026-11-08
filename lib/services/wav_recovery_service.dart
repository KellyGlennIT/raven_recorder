import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Repairs the header of a RAVEN PCM16 WAV source after process interruption.
class WavRecoveryService {
  Future<int?> repairPcm16File(
    File file, {
    required int sampleRate,
    int channels = 1,
  }) async {
    if (!await file.exists()) return null;
    final length = await file.length();
    const headerLength = 44;
    const bytesPerSample = 2;
    final frameSize = bytesPerSample * channels;
    final dataLength =
        ((length - headerLength).clamp(0, 0xFFFFFFFF - headerLength) ~/
                frameSize) *
            frameSize;
    if (dataLength == 0) return null;

    final rate = sampleRate.clamp(8000, 192000);
    final header = ByteData(headerLength);
    final view = header.buffer.asUint8List();
    view.setRange(0, 4, ascii.encode('RIFF'));
    header.setUint32(4, headerLength - 8 + dataLength, Endian.little);
    view.setRange(8, 12, ascii.encode('WAVE'));
    view.setRange(12, 16, ascii.encode('fmt '));
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, rate, Endian.little);
    header.setUint32(28, rate * frameSize, Endian.little);
    header.setUint16(32, frameSize, Endian.little);
    header.setUint16(34, bytesPerSample * 8, Endian.little);
    view.setRange(36, 40, ascii.encode('data'));
    header.setUint32(40, dataLength, Endian.little);

    final handle = await file.open(mode: FileMode.writeOnly);
    try {
      await handle.setPosition(0);
      await handle.writeFrom(view);
      await handle.truncate(headerLength + dataLength);
      await handle.flush();
    } finally {
      await handle.close();
    }

    return (dataLength * 1000) ~/ (rate * frameSize);
  }
}
