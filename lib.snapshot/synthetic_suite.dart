// lib/synthetic_suite.dart
//
// Synthetic test generator for HarmoniQ Day 3 accuracy runs.
// Creates on-device WAV files: clean clicks, shaker-like patterns, and
// optional noise or light HPSS-style mixes.
//
// Requires: path_provider
// Add to pubspec.yaml if not present:
//   path_provider: ^2.1.4
//
// Usage example:
//
// final gen = SyntheticSuite(sampleRate: 44100);
// final dir = await gen.ensureOutputDir("synthetic_day3");
// await gen.generateBatch(
//   outDir: dir,
//   cases: [
//     SynthCase(bpm: 80, seconds: 20),
//     SynthCase(bpm: 90, seconds: 20, noiseDbFs: -40),
//     SynthCase(bpm: 120, seconds: 20, pattern: SynthPattern.shaker),
//     SynthCase(bpm: 128, seconds: 20, clickDensity: 2),
//     SynthCase(bpm: 140, seconds: 20, hpssHarmonicPct: 20, hpssPercussivePct: 80),
//   ],
// );

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

enum SynthPattern { click, shaker }

class SynthCase {
  final double bpm;
  final int seconds;
  final int clickDensity; // 1 = beats only, 2 = 8th notes, 4 = 16th notes
  final SynthPattern pattern;
  final double noiseDbFs; // e.g., -50 dBFS
  final int hpssHarmonicPct; // 0..100
  final int hpssPercussivePct; // 0..100

  const SynthCase({
    required this.bpm,
    required this.seconds,
    this.clickDensity = 1,
    this.pattern = SynthPattern.click,
    this.noiseDbFs = double.nan, // NaN = none
    this.hpssHarmonicPct = 0,
    this.hpssPercussivePct = 100,
  });
}

class SyntheticSuite {
  final int sampleRate;

  SyntheticSuite({this.sampleRate = 44100});

  Future<String> ensureOutputDir(String folderName) async {
    final base = await getApplicationDocumentsDirectory();
    final out = Directory("${base.path}/$folderName");
    if (!await out.exists()) {
      await out.create(recursive: true);
    }
    return out.path;
  }

  Future<File> generateCase({
    required String outDir,
    required SynthCase cfg,
    String? fileLabel,
  }) async {
    final label = fileLabel ??
        "${cfg.pattern.name}_${cfg.bpm.toStringAsFixed(1)}bpm_${cfg.seconds}s_d${cfg.clickDensity}";
    final path = "$outDir/$label.wav";
    final samples = _render(cfg);
    final wav = _encodeWav(samples, sampleRate: sampleRate);
    final f = File(path);
    await f.writeAsBytes(wav, flush: true);
    return f;
  }

  Future<List<File>> generateBatch({
    required String outDir,
    required List<SynthCase> cases,
  }) async {
    final files = <File>[];
    for (final c in cases) {
      files.add(await generateCase(outDir: outDir, cfg: c));
    }
    return files;
  }

  // ---------------- Rendering ----------------

  Float32List _render(SynthCase cfg) {
    final totalSamples = cfg.seconds * sampleRate;
    final buf = Float32List(totalSamples);

    // Base timeline
    final beatsPerSec = cfg.bpm / 60.0;
    final baseInterval = sampleRate / beatsPerSec;
    final subDiv = math.max(1, cfg.clickDensity);
    final interval = baseInterval / subDiv;

    // Pattern generators
    if (cfg.pattern == SynthPattern.click) {
      _synthesizeClicks(buf, interval, subDiv);
    } else {
      _synthesizeShaker(buf, interval, subDiv);
    }

    // Optional HPSS mix proxy: slight smearing to emulate percussive vs harmonic
    if (cfg.hpssHarmonicPct > 0 || cfg.hpssPercussivePct < 100) {
      _applySimpleSmearing(
        buf,
        harmonicPct: cfg.hpssHarmonicPct,
        percussivePct: cfg.hpssPercussivePct,
      );
    }

    // Optional noise
    if (!cfg.noiseDbFs.isNaN) {
      _mixWhiteNoise(buf, cfg.noiseDbFs);
    }

    // Normalize to safe headroom
    _normalize(buf, -1.0); // 1 dBFS headroom
    return buf;
  }

  void _synthesizeClicks(Float32List buf, double interval, int subDiv) {
    final clickLen = (0.006 * sampleRate).round(); // 6 ms click
    for (int i = 0; i < buf.length; i += interval.round()) {
      for (int k = 0; k < clickLen && i + k < buf.length; k++) {
        // Simple decaying exponential
        final amp = math.exp(-k / (0.0015 * sampleRate));
        buf[i + k] += 0.9 * amp;
      }
    }
  }

  void _synthesizeShaker(Float32List buf, double interval, int subDiv) {
    final grainLen = (0.015 * sampleRate).round(); // 15 ms grains
    final rnd = math.Random(7);
    for (int i = 0; i < buf.length; i += interval.round()) {
      for (int k = 0; k < grainLen && i + k < buf.length; k++) {
        final noise = (rnd.nextDouble() * 2.0 - 1.0);
        final env = math.exp(-k / (0.006 * sampleRate));
        buf[i + k] += 0.5 * noise * env;
      }
    }
  }

  void _applySimpleSmearing(
    Float32List buf, {
    required int harmonicPct,
    required int percussivePct,
  }) {
    // Two crude one-pole filters approximating different spreads
    const aH = 0.98; // slow, "harmonic"
    const aP = 0.35; // fast, "percussive"
    double yh = 0.0, yp = 0.0;
    for (int i = 0; i < buf.length; i++) {
      yh = aH * yh + (1 - aH) * buf[i];
      yp = aP * yp + (1 - aP) * buf[i];
      final mix =
          (harmonicPct / 100.0) * yh + (percussivePct / 100.0) * (buf[i] - yp);
      buf[i] = mix.clamp(-1.5, 1.5);
    }
  }

  void _mixWhiteNoise(Float32List buf, double noiseDbFs) {
    final rnd = math.Random(13);
    final targetRms = _dbToLinear(
      noiseDbFs + 3.01,
    ); // white noise crest factor ~3 dB
    for (int i = 0; i < buf.length; i++) {
      final n = (rnd.nextDouble() * 2.0 - 1.0);
      buf[i] += n * targetRms;
    }
  }

  void _normalize(Float32List buf, double headroomDb) {
    double maxAbs = 1e-12;
    for (final v in buf) {
      final a = v.abs();
      if (a > maxAbs) maxAbs = a;
    }
    final target = _dbToLinear(headroomDb);
    final g = (maxAbs > 0) ? target / maxAbs : 1.0;
    for (int i = 0; i < buf.length; i++) {
      buf[i] = (buf[i] * g).clamp(-1.0, 1.0);
    }
  }

  // ---------------- WAV encode ----------------

  List<int> _encodeWav(Float32List samples, {required int sampleRate}) {
    // 16-bit PCM WAV
    const bytesPerSample = 2;
    const numChannels = 1;
    final dataSize = samples.length * bytesPerSample;
    const headerSize = 44;
    final totalSize = headerSize + dataSize;

    final out = BytesBuilder();

    void writeString(String s) {
      out.add(s.codeUnits);
    }

    void writeUint32(int v) {
      final b = ByteData(4)..setUint32(0, v, Endian.little);
      out.add(b.buffer.asUint8List());
    }

    void writeUint16(int v) {
      final b = ByteData(2)..setUint16(0, v, Endian.little);
      out.add(b.buffer.asUint8List());
    }

    // RIFF header
    writeString('RIFF');
    writeUint32(totalSize - 8);
    writeString('WAVE');

    // fmt chunk
    writeString('fmt ');
    writeUint32(16); // PCM
    writeUint16(1); // AudioFormat = PCM
    writeUint16(numChannels);
    writeUint32(sampleRate);
    writeUint32(sampleRate * numChannels * bytesPerSample);
    writeUint16(numChannels * bytesPerSample);
    writeUint16(16);

    // data chunk
    writeString('data');
    writeUint32(dataSize);

    // samples
    final bd = ByteData(samples.length * 2);
    for (int i = 0; i < samples.length; i++) {
      final s = (samples[i] * 32767.0).clamp(-32768.0, 32767.0);
      bd.setInt16(i * 2, s.round(), Endian.little);
    }
    out.add(bd.buffer.asUint8List());
    return out.toBytes();
  }

  double _dbToLinear(double db) => math.pow(10.0, db / 20.0) as double;
}
