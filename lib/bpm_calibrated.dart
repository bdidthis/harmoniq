// lib/bpm_calibrated.dart
// Builds a BpmEstimator using a calibration "recommendation" (min/max BPM).
// Compatible with the current BpmEstimator constructor:
//   BpmEstimator({required sampleRate, double minBpm = 60, double maxBpm = 180})

import 'bpm_estimator.dart';
import 'calibration_tools.dart';

class EstimatorBuildArgs {
  final int sampleRate;
  final int frameSize;
  final double windowSeconds;
  final double emaAlpha;
  final int historyLength;

  // Song-optimized parameters (not used by current ctor)
  final bool useSpectralFlux;
  final double onsetSensitivity;
  final int medianFilterSize;
  final double adaptiveThresholdRatio;
  final double hypothesisDecay;
  final double switchThreshold;
  final int switchHoldFrames;
  final double lockStability;
  final double unlockStability;
  final double reportDeadbandUnlocked;
  final double reportDeadbandLocked;
  final double reportQuantUnlocked;
  final double reportQuantLocked;
  final double minEnergyDb;

  // Fallback BPM range
  final double fallbackMinBpm;
  final double fallbackMaxBpm;

  const EstimatorBuildArgs({
    required this.sampleRate,
    this.frameSize = 1024,
    this.windowSeconds = 12.0,
    this.emaAlpha = 0.12,
    this.historyLength = 36,
    this.useSpectralFlux = true,
    this.onsetSensitivity = 0.9,
    this.medianFilterSize = 9,
    this.adaptiveThresholdRatio = 1.7,
    this.hypothesisDecay = 0.97,
    this.switchThreshold = 1.35,
    this.switchHoldFrames = 6,
    this.lockStability = 0.80,
    this.unlockStability = 0.55,
    this.reportDeadbandUnlocked = 0.04,
    this.reportDeadbandLocked = 0.24,
    this.reportQuantUnlocked = 0.02,
    this.reportQuantLocked = 0.08,
    this.minEnergyDb = -60.0,
    this.fallbackMinBpm = 60.0,
    this.fallbackMaxBpm = 190.0,
  });
}

class CalibratedEstimator {
  static BpmEstimator fromRecommendation({
    required Object rec, // dynamic-ish to cooperate with calibrator type
    required EstimatorBuildArgs args,
  }) {
    double _readMin(Object r) {
      try {
        final v = (r as dynamic).minBpm as double?;
        if (v != null && v > 0) return v;
      } catch (_) {}
      return args.fallbackMinBpm;
    }

    double _readMax(Object r) {
      try {
        final v = (r as dynamic).maxBpm as double?;
        if (v != null && v > 0) return v;
      } catch (_) {}
      return args.fallbackMaxBpm;
    }

    double minBpm = _readMin(rec);
    double maxBpm = _readMax(rec);

    if (!(minBpm.isFinite) || !(maxBpm.isFinite) || minBpm >= maxBpm) {
      minBpm = args.fallbackMinBpm;
      maxBpm = args.fallbackMaxBpm;
    }

    return BpmEstimator(
      sampleRate: args.sampleRate,
      minBpm: minBpm,
      maxBpm: maxBpm,
    );
  }
}
