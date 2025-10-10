import 'dart:math' as math;
import 'dart:typed_data';

class PitchReading {
  final double hz;
  final String note;
  final double cents;
  final double confidence;
  const PitchReading(this.hz, this.note, this.cents, this.confidence);
}

class PitchTracker {
  final int sampleRate;
  final int window;
  final int hop;
  final double minHz;
  final double maxHz;

  final List<double> _ring = <double>[];
  PitchReading _last = const PitchReading(0, '--', 0, 0);

  PitchTracker({
    required this.sampleRate,
    this.window = 4096,
    this.hop = 1024,
    this.minHz = 55.0,
    this.maxHz = 1000.0,
  });

  PitchReading get reading => _last;

  void reset() {
    _ring.clear();
    _last = const PitchReading(0, '--', 0, 0);
  }

  void addBytes(
    Uint8List bytes, {
    required int channels,
    required bool isFloat32,
  }) {
    final bd = ByteData.sublistView(bytes);
    if (isFloat32) {
      final count = bytes.length ~/ 4;
      for (int i = 0; i < count; i += channels) {
        double s = 0.0;
        for (int ch = 0; ch < channels; ch++) {
          s += bd.getFloat32(4 * (i + ch), Endian.little);
        }
        _push(s / channels);
      }
    } else {
      final count = bytes.length ~/ 2;
      for (int i = 0; i < count; i += channels) {
        double s = 0.0;
        for (int ch = 0; ch < channels; ch++) {
          s += bd.getInt16(2 * (i + ch), Endian.little) / 32768.0;
        }
        _push(s / channels);
      }
    }
  }

  void _push(double s) {
    _ring.add(s);
    while (_ring.length >= window) {
      final frame = List<double>.from(_ring.getRange(0, window));
      _process(frame);
      _ring.removeRange(0, hop);
    }
  }

  void _process(List<double> x) {
    final n = x.length;
    double mean = 0.0;
    for (final v in x) {
      mean += v;
    }
    mean /= n;
    for (int i = 0; i < n; i++) {
      x[i] -= mean;
    }
    double energy = 0.0;
    for (final v in x) {
      energy += v * v;
    }
    if (energy <= 1e-9) return;

    final int maxLag = math.min((sampleRate / minHz).floor(), n - 1);
    final int minLag = math.max(1, (sampleRate / maxHz).floor());
    double best = 0.0;
    int bestLag = -1;
    for (int lag = minLag; lag <= maxLag; lag++) {
      double s = 0.0;
      for (int i = lag; i < n; i++) {
        s += x[i] * x[i - lag];
      }
      if (s > best) {
        best = s;
        bestLag = lag;
      }
    }
    if (bestLag <= 0) return;

    double y0 = 0.0, y1 = 0.0, y2 = 0.0;
    for (int i = bestLag - 1; i < n; i++) {
      y0 += x[i] * x[i - (bestLag - 1)];
    }
    for (int i = bestLag; i < n; i++) {
      y1 += x[i] * x[i - bestLag];
    }
    for (int i = bestLag + 1; i < n; i++) {
      y2 += x[i] * x[i - (bestLag + 1)];
    }
    double denom = (y0 - 2 * y1 + y2);
    double shift = denom.abs() < 1e-9 ? 0.0 : 0.5 * (y0 - y2) / denom;
    final lagRefined = (bestLag + shift).clamp(
      minLag.toDouble(),
      maxLag.toDouble(),
    );
    final freq = sampleRate / lagRefined;
    if (freq.isNaN || freq.isInfinite) return;
    if (freq < minHz || freq > maxHz) return;

    final midi = 69.0 + 12.0 * (math.log(freq / 440.0) / math.ln2);
    final midiRound = midi.round();
    final cents = (midi - midiRound) * 100.0;
    final label = _midiToLabel(midiRound);
    final conf = (y1 / energy).clamp(0.0, 1.0);
    _last = PitchReading(freq, label, cents, conf);
  }

  String _midiToLabel(int m) {
    if (m <= 0 || m >= 128) return '--';
    const names = [
      'C',
      'C#',
      'D',
      'D#',
      'E',
      'F',
      'F#',
      'G',
      'G#',
      'A',
      'A#',
      'B',
    ];
    final pc = m % 12;
    final oct = (m ~/ 12) - 1;
    return '${names[pc]}$oct';
  }
}
