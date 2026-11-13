import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:path_provider/path_provider.dart';

class WaveformService {
  WaveformService._();
  static final WaveformService instance = WaveformService._();

  final Map<String, File?> _memoryCache = {};

  Future<File?> getWaveform(File audioFile) async {
    final path = audioFile.path;
    if (_memoryCache.containsKey(path)) return _memoryCache[path];

    try {
      final cache = await getTemporaryDirectory();
      final hash = path.hashCode;
      final waveFile = File('${cache.path}/wave_$hash.png');
      
      // Return cached image if it exists
      if (await waveFile.exists()) {
        _memoryCache[path] = waveFile;
        return waveFile;
      }

      // Generate a 1000px wide waveform image with a blue color
      final cmd = '-y -i "$path" -filter_complex "showwavespic=s=1000x100:colors=#2196F3" -frames:v 1 "${waveFile.path}"';
      final session = await FFmpegKit.execute(cmd);
      final code = await session.getReturnCode();
      
      if (code != null && ReturnCode.isSuccess(code) && await waveFile.exists()) {
        _memoryCache[path] = waveFile;
        return waveFile;
      }
    } catch (_) {}
    
    _memoryCache[path] = null;
    return null;
  }
}