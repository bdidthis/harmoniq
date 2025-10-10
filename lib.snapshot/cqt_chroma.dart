import 'dart:math' as math;

class CqtChroma {
  final int sampleRate;
  final double minHz;
  final double maxHz;
  final int binsPerOctave; // currently unused, but kept for future mapping
  final double spreadCents;

  // Packed mapping:
  // For each FFT bin k in [1..half-1], we may append one or more (pc, weight)
  // entries. _index[k] stores the exclusive end offset into _pcMap/_weights.
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

  /// Build (or rebuild) mapping for a given spectrum half-length and bin Hz.
  /// halfBins should be mags.length (i.e., fftSize/2).
  void buildMapping(int halfBins, double binHz, double tuningCents) {
    _pcMap.clear();
    _weights.clear();
    _index.clear();

    // Ensure _index has exactly halfBins elements: k ∈ [0..halfBins-1].
    // k = 0 (DC) has no mapping; record end offset 0.
    _index.add(0);

    // Gaussian around the nearest semitone in cents.
    // sigma (in semitones) from a desired spread in cents.
    final double sigma = (spreadCents / 100.0) / 2.354820045; // 2*sqrt(2*ln2)
    final bool hasSigma = sigma.isFinite && sigma > 0.0;

    for (int k = 1; k < halfBins; k++) {
      final double f = k * binHz;
      if (!(f.isFinite) || f < minHz || f > maxHz) {
        // No entries for this bin; carry forward previous end.
        _index.add(_weights.length);
        continue;
      }

      // Map to nearest MIDI (with tuning offset in cents).
      final double midi =
          69 + 12 * (math.log(f / 440.0) / math.ln2) + (tuningCents / 100.0);
      final double mRound = midi.roundToDouble();
      final int pc = ((mRound.toInt() % 12) + 12) % 12;

      // Weight: either Gaussian around the rounded pitch, or 1.0 if sigma==0.
      double w = 1.0;
      if (hasSigma) {
        final double dist = (midi - mRound).abs(); // in semitones
        w = math.exp(-0.5 * (dist * dist) / (sigma * sigma));
      }

      // Append one packed entry for this bin (future-proof: we may add more).
      _pcMap.add(pc);
      _weights.add(w);

      // Record exclusive end offset for this k.
      _index.add(_weights.length);
    }

    // Invariant: _index.length == halfBins
    //            0 == _index[0] <= _index[1] <= ... <= _index[halfBins-1] == _weights.length
  }

  /// Compute 12-D chroma from a magnitude spectrum.
  /// - mag.length should be halfBins (fftSize/2).
  /// - binHz = sampleRate / fftSize (caller supplies).
  /// - tuningCents offsets reference tuning.
  List<double> chromaFromSpectrum(
    List<double> mag,
    double binHz,
    double tuningCents,
  ) {
    final int half = mag.length;
    if (half <= 1) return List<double>.filled(12, 0.0);

    // Rebuild mapping if shape changed.
    if (_index.length != half) {
      buildMapping(half, binHz, tuningCents);
    }

    final List<double> c = List<double>.filled(12, 0.0);

    // Accumulate per FFT bin k using packed entries in [_index[k-1], _index[k]).
    for (int k = 1; k < half; k++) {
      // Bounds-safe: _index has length == half
      final int end = _index[k];
      final int start = _index[k - 1];
      final int span = end - start;
      if (span <= 0) continue;

      final double v = mag[k];
      if (!v.isFinite || v <= 0) continue;

      // IMPORTANT: Sum **all** entries for this bin (not just the first).
      // This keeps the code correct if/when mapping adds multiple weights per bin.
      for (int i = start; i < end; i++) {
        // Additional defensive bounds (should not trigger if mapping is consistent)
        if (i < 0 || i >= _pcMap.length || i >= _weights.length) break;
        final int pc = _pcMap[i];
        final double w = _weights[i];
        if (w != 0.0) c[pc] += v * w;
      }
    }

    // Normalize to sum==1 (if nonzero)
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
