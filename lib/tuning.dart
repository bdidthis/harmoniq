// lib/tuning.dart
import 'dart:math' as math;

class TuningEstimator {
  final double minCents;
  final double maxCents;
  final double stepCents;

  const TuningEstimator({
    this.minCents = -50.0,
    this.maxCents = 50.0,
    this.stepCents = 1.0,
  });

  double estimateCents(List<double> spectrum, double binHz) {
    if (spectrum.isEmpty || !binHz.isFinite || binHz <= 0) return 0.0;

    final steps = ((maxCents - minCents) / stepCents).round() + 1;
    double bestScore = -1.0e9;
    double bestCents = 0.0;

    for (int i = 0; i < steps; i++) {
      final cents = minCents + i * stepCents;
      final s = _scoreAtCents(spectrum, binHz, cents);
      if (s > bestScore) {
        bestScore = s;
        bestCents = cents;
      }
    }
    return bestCents;
  }

  double _scoreAtCents(List<double> spec, double binHz, double cents) {
    // Precomputed ln(2) to avoid any SDK variance.
    const double ln2 = 0.6931471805599453;
    const double sigma = 0.18; // in semitones

    double score = 0.0;
    for (int k = 1; k < spec.length; k++) {
      final f = k * binHz;
      if (!f.isFinite || f < 40.0 || f > 6000.0) continue;

      final midi = 69.0 + 12.0 * (math.log(f / 440.0) / ln2) + cents / 100.0;
      final dist = (midi - midi.round()).abs(); // distance to nearest semitone
      final win = math.exp(-0.5 * (dist * dist) / (sigma * sigma));
      score += spec[k] * win;
    }
    return score;
  }
}
