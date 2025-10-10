import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';

class Metronome {
  final AudioPlayer _player = AudioPlayer();
  Timer? _timer;
  double _bpm = 0.0;
  late final Uint8List _clickBytes;

  Metronome() {
    _clickBytes = _makeClick(sampleRate: 44100, ms: 15, freqHz: 1200);
  }

  void setBpm(double bpm) {
    _bpm = bpm;
    if (_timer != null) {
      start();
    }
  }

  void start() {
    stop();
    if (_bpm <= 0) return;
    final intervalMs = (60000.0 / _bpm).round();
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      _player.play(BytesSource(_clickBytes));
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Uint8List _makeClick({
    required int sampleRate,
    required int ms,
    required int freqHz,
  }) {
    final samples = ((sampleRate * ms) / 1000).round();
    final bytes = BytesBuilder();
    final pcm = BytesBuilder();
    for (int n = 0; n < samples; n++) {
      final t = n / sampleRate;
      final env = (1.0 - n / samples).clamp(0.0, 1.0);
      final v = math.sin(2 * math.pi * freqHz * t) * env * 0.7;
      final s = (v * 32767.0).round().clamp(-32768, 32767);
      pcm.add([s & 0xFF, (s >> 8) & 0xFF]);
    }
    final dataSize = pcm.length;
    const fmtChunkSize = 16;
    const audioFormat = 1;
    const numChannels = 1;
    final byteRate = sampleRate * numChannels * 2;
    const blockAlign = numChannels * 2;
    const bitsPerSample = 16;
    final riffSize = 36 + dataSize;
    bytes.add([0x52, 0x49, 0x46, 0x46]);
    bytes.add([
      riffSize & 0xFF,
      (riffSize >> 8) & 0xFF,
      (riffSize >> 16) & 0xFF,
      (riffSize >> 24) & 0xFF,
    ]);
    bytes.add([0x57, 0x41, 0x56, 0x45]);
    bytes.add([0x66, 0x6D, 0x74, 0x20]);
    bytes.add([fmtChunkSize, 0x00, 0x00, 0x00]);
    bytes.add([audioFormat, 0x00]);
    bytes.add([numChannels, 0x00]);
    bytes.add([
      sampleRate & 0xFF,
      (sampleRate >> 8) & 0xFF,
      (sampleRate >> 16) & 0xFF,
      (sampleRate >> 24) & 0xFF,
    ]);
    bytes.add([
      byteRate & 0xFF,
      (byteRate >> 8) & 0xFF,
      (byteRate >> 16) & 0xFF,
      (byteRate >> 24) & 0xFF,
    ]);
    bytes.add([blockAlign, 0x00]);
    bytes.add([bitsPerSample, 0x00]);
    bytes.add([0x64, 0x61, 0x74, 0x61]);
    bytes.add([
      dataSize & 0xFF,
      (dataSize >> 8) & 0xFF,
      (dataSize >> 16) & 0xFF,
      (dataSize >> 24) & 0xFF,
    ]);
    bytes.add(pcm.toBytes());
    return bytes.toBytes();
  }
}
