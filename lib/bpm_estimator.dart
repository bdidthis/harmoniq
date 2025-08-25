import 'dart:math' as math;
import 'dart:typed_data';

class BpmEstimator {
  final int sampleRate;
  final double minBpm;
  final double maxBpm;

  static const int _win = 1024;
  static const int _hop = 512;
  static const double _windowSeconds = 8.0;

  final List<double> _samples = <double>[];
  int _cursor = 0;
  final List<double> _env = <double>[];
  final List<double> _envTime = <double>[];

  double? _bpmSmoothed;

  BpmEstimator({required this.sampleRate, this.minBpm = 60.0, this.maxBpm = 180.0});

  double? get bpm => _bpmSmoothed;

  void addBytes(Uint8List bytes, {required int channels, required bool isFloat32}) {
    final mono = _toMonoFloats(bytes, channels: channels, isFloat32: isFloat32);
    if (mono.isEmpty) return;

    _samples.addAll(mono);

    if (_cursor == 0 && _samples.length >= _win) {
      _cursor = _win;
    }

    while (_cursor + _hop <= _samples.length) {
      final start = _cursor - _win;
      final end = _cursor;
      double sum = 0.0;
      for (int i = start; i < end; i++) {
        final s = _samples[i];
        sum += s * s;
      }
      final rms = math.sqrt(sum / _win);
      _env.add(rms);
      _envTime.add(_cursor / sampleRate.toDouble());
      _cursor += _hop;
    }

    final keepFrom = math.max(0, _cursor - _win - 10 * _hop);
    if (keepFrom > 0) {
      _samples.removeRange(0, keepFrom);
      _cursor -= keepFrom;
    }

    if (_envTime.isNotEmpty) {
      final nowT = _envTime.last;
      final cutoff = nowT - _windowSeconds;
      int firstIdx = 0;
      while (firstIdx < _envTime.length && _envTime[firstIdx] < cutoff) {
        firstIdx++;
      }
      if (firstIdx > 0) {
        _env.removeRange(0, firstIdx);
        _envTime.removeRange(0, firstIdx);
      }
    }

    _updateBpm();
  }

  void _updateBpm() {
    if (_env.length < 6) return;

    final int n = _env.length;
    final List<double> diff = List<double>.filled(n, 0.0);
    for (int i = 1; i < n; i++) {
      final d = _env[i] - _env[i - 1];
      diff[i] = d > 0 ? d : 0.0;
    }

    double mean = 0.0;
    for (int i = 0; i < n; i++) {
      mean += diff[i];
    }
    mean /= n;

    double variance = 0.0;
    for (int i = 0; i < n; i++) {
      final x = diff[i] - mean;
      variance += x * x;
    }
    variance /= math.max(1, n - 1);
    final double std = math.sqrt(variance);
    final double thr = mean + 0.5 * std;

    final List<double> onsetTimes = <double>[];
    for (int i = 1; i < n - 1; i++) {
      final a = diff[i - 1], b = diff[i], c = diff[i + 1];
      if (b > thr && b > a && b > c) {
        onsetTimes.add(_envTime[i]);
      }
    }
    if (onsetTimes.length < 3) return;

    final double minIOI = 60.0 / maxBpm;
    final double maxIOI = 60.0 / minBpm;

    final Map<int, double> hist = <int, double>{};
    for (int i = 1; i < onsetTimes.length; i++) {
      final ioi = onsetTimes[i] - onsetTimes[i - 1];
      if (ioi <= 1e-6) continue;
      if (ioi < minIOI || ioi > maxIOI) continue;

      double cand = 60.0 / ioi;
      while (cand < minBpm) cand *= 2.0;
      while (cand > maxBpm) cand /= 2.0;

      final int bin = cand.round();
      final double w = 1.0 / (1.0 + (cand - bin).abs());
      hist.update(bin, (v) => v + w, ifAbsent: () => w);
    }
    if (hist.isEmpty) return;

    int bestBin = hist.keys.first;
    double bestW = hist[bestBin]!;
    hist.forEach((k, w) {
      if (w > bestW) {
        bestW = w;
        bestBin = k;
      }
    });

    final double newBpm = bestBin.toDouble();
    if (_bpmSmoothed == null) {
      _bpmSmoothed = newBpm;
    } else {
      _bpmSmoothed = 0.7 * _bpmSmoothed! + 0.3 * newBpm;
    }
  }

  static List<double> _toMonoFloats(Uint8List bytes, {required int channels, required bool isFloat32}) {
    if (isFloat32) {
      final Float32List f = bytes.buffer.asFloat32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
      if (channels <= 1) {
        return f.toList(growable: false);
      } else {
        final int frames = f.length ~/ channels;
        final List<double> out = List<double>.filled(frames, 0.0);
        int idx = 0;
        for (int i = 0; i < frames; i++) {
          double sum = 0.0;
          for (int c = 0; c < channels; c++) {
            sum += f[idx++];
          }
          out[i] = sum / channels;
        }
        return out;
      }
    } else {
      final Int16List i16 = bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
      if (channels <= 1) {
        final List<double> out = List<double>.filled(i16.length, 0.0);
        for (int i = 0; i < i16.length; i++) {
          out[i] = i16[i] / 32768.0;
        }
        return out;
      } else {
        final int frames = i16.length ~/ channels;
        final List<double> out = List<double>.filled(frames, 0.0);
        int idx = 0;
        for (int i = 0; i < frames; i++) {
          double sum = 0.0;
          for (int c = 0; c < channels; c++) {
            sum += i16[idx++] / 32768.0;
          }
          out[i] = sum / channels;
        }
        return out;
      }
    }
  }
}
