import 'dart:math' as math;

class TuningEstimator {
  final double minCents;
  final double maxCents;
  final double stepCents;
  TuningEstimator({
    this.minCents = -50,
    this.maxCents = 50,
    this.stepCents = 1,
  });
  double estimateCents(List<double> spectrum, double binHz) {
    if (spectrum.isEmpty || binHz <= 0) return 0;
    final steps = ((maxCents - minCents) / stepCents).round() + 1;
    double bestScore = -1e9;
    double bestCents = 0;
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
    double score = 0;
    for (int k = 1; k < spec.length; k++) {
      final f = k * binHz;
      if (f < 40 || f > 6000) continue;
      final midi = 69 + 12 * (math.log(f / 440.0) / math.ln2) + cents / 100.0;
      final dist = (midi - midi.round()).abs();
      final win = math.exp(-0.5 * (dist * dist) / (0.18 * 0.18));
      score += spec[k] * win;
    }
    return score;
  }
}
