import 'dart:math' as math;

class CqtChroma {
  final int sampleRate;
  final double minHz;
  final double maxHz;
  final int binsPerOctave; // currently unused, kept for future mapping
  final double spreadCents;

  // Packed mapping:
  // For each FFT bin k in [1..half-1], append one or more (pc, weight) entries.
  // _index[k] stores the exclusive end offset into _pcMap/_weights.
  final List<int> _pcMap = <int>[];
  final List<double> _weights = <double>[];
  final List<int> _index = <int>[]; // length == halfBins

  CqtChroma({
    required this.sampleRate,
    this.minHz = 55.0,
    this.maxHz = 5500.0,
    this.binsPerOctave = 36,
    this.spreadCents = 60.0,
  });

  void buildMapping(int halfBins, double binHz, double tuningCents) {
    _pcMap.clear();
    _weights.clear();
    _index.clear();

    _index.add(0); // k=0 has no mapping

    final double sigma = (spreadCents / 100.0) / 2.354820045; // 2*sqrt(2*ln2)
    final bool hasSigma = sigma.isFinite && sigma > 0.0;

    for (int k = 1; k < halfBins; k++) {
      final double f = k * binHz;
      if (!(f.isFinite) || f < minHz || f > maxHz) {
        _index.add(_weights.length);
        continue;
      }

      final double midi =
          69 + 12 * (math.log(f / 440.0) / math.ln2) + (tuningCents / 100.0);
      final double mRound = midi.roundToDouble();
      final int pc = ((mRound.toInt() % 12) + 12) % 12;

      double w = 1.0;
      if (hasSigma) {
        final double dist = (midi - mRound).abs(); // in semitones
        w = math.exp(-0.5 * (dist * dist) / (sigma * sigma));
      }

      _pcMap.add(pc);
      _weights.add(w);

      _index.add(_weights.length);
    }
  }

  List<double> chromaFromSpectrum(
    List<double> mag,
    double binHz,
    double tuningCents,
  ) {
    final int half = mag.length;
    if (half <= 1) return List<double>.filled(12, 0.0);

    if (_index.length != half) {
      buildMapping(half, binHz, tuningCents);
    }

    final List<double> c = List<double>.filled(12, 0.0);

    for (int k = 1; k < half; k++) {
      final int end = _index[k];
      final int start = _index[k - 1];
      final int span = end - start;
      if (span <= 0) continue;

      final double v = mag[k];
      if (!v.isFinite || v <= 0) continue;

      for (int i = start; i < end; i++) {
        if (i < 0 || i >= _pcMap.length || i >= _weights.length) break;
        final int pc = _pcMap[i];
        final double w = _weights[i];
        if (w != 0.0) c[pc] += v * w;
      }
    }

    double sum = 0.0;
    for (final v in c) {
      sum += v;
    }
    if (sum > 0) {
      for (int i = 0; i < 12; i++) {
        c[i] /= sum;
      }
    }
    return c;
  }
}
