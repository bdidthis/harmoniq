// Simple calibration helpers for constraining BPM search

class CalibrateRecommendation {
  final double minBpm;
  final double maxBpm;
  final double preferredBandLow;
  final double preferredBandHigh;

  const CalibrateRecommendation({
    required this.minBpm,
    required this.maxBpm,
    required this.preferredBandLow,
    required this.preferredBandHigh,
  });
}

enum HintBandTightness { loose, medium, tight }

class HintCalibrator {
  final double? hintBpm;
  final HintBandTightness bandTightness;
  final double defaultMinBpm;
  final double defaultMaxBpm;

  HintCalibrator({
    this.hintBpm,
    this.bandTightness = HintBandTightness.medium,
    this.defaultMinBpm = 60.0,
    this.defaultMaxBpm = 190.0,
  });

  CalibrateRecommendation recommend() {
    if (hintBpm == null || hintBpm! <= 0) {
      return CalibrateRecommendation(
        minBpm: defaultMinBpm,
        maxBpm: defaultMaxBpm,
        preferredBandLow: defaultMinBpm,
        preferredBandHigh: defaultMaxBpm,
      );
    }

    final double center = hintBpm!;
    double range;
    switch (bandTightness) {
      case HintBandTightness.loose:
        range = 40.0;
        break;
      case HintBandTightness.medium:
        range = 25.0;
        break;
      case HintBandTightness.tight:
        range = 15.0;
        break;
    }

    final double minBpm = (center - range).clamp(30.0, defaultMaxBpm);
    final double maxBpm = (center + range).clamp(minBpm + 10, 250.0);

    return CalibrateRecommendation(
      minBpm: minBpm,
      maxBpm: maxBpm,
      preferredBandLow: (center - range * 0.5).clamp(minBpm, maxBpm),
      preferredBandHigh: (center + range * 0.5).clamp(minBpm, maxBpm),
    );
  }

  CalibrateRecommendation finalizeTightening(CalibrateRecommendation rec) {
    final double center = (rec.preferredBandLow + rec.preferredBandHigh) / 2;
    const double tightRange = 10.0;

    return CalibrateRecommendation(
      minBpm: (center - tightRange).clamp(30.0, rec.maxBpm),
      maxBpm: (center + tightRange).clamp(rec.minBpm + 5, 250.0),
      preferredBandLow:
          (center - tightRange * 0.3).clamp(rec.minBpm, rec.maxBpm),
      preferredBandHigh:
          (center + tightRange * 0.3).clamp(rec.minBpm, rec.maxBpm),
    );
  }
}
