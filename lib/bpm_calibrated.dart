// lib/bpm_calibrated.dart
// Builds a BpmEstimator using a calibration "recommendation" (min/max BPM).
// NOW PROPERLY PASSES ALL PARAMETERS TO ESTIMATOR

import 'bpm_estimator.dart';
import 'calibration_tools.dart';

class EstimatorBuildArgs {
  final int sampleRate;
  final int frameSize;
  final double windowSeconds;
  final double emaAlpha;
  final int historyLength;

  final bool useSpectralFlux;
  final double onsetSensitivity;
  final int medianFilterSize;
  final double adaptiveThresholdRatio;
  final double hypothesisDecay;
  final double switchThreshold;
  final int switchHoldFrames;
  final double lockStabilityHi;
  final double lockStabilityLo;
  final double beatsToLock;
  final double beatsToUnlock;
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
    this.lockStabilityHi = 0.80,
    this.lockStabilityLo = 0.55,
    this.beatsToLock = 4.5,
    this.beatsToUnlock = 2.5,
    this.reportDeadbandUnlocked = 0.04,
    this.reportDeadbandLocked = 0.12,
    this.reportQuantUnlocked = 0.02,
    this.reportQuantLocked = 0.05,
    this.minEnergyDb = -60.0,
    this.fallbackMinBpm = 60.0,
    this.fallbackMaxBpm = 190.0,
  });
}

class CalibratedEstimator {
  static BpmEstimator fromRecommendation({
    required Object rec,
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

    // NOW PROPERLY PASSES ALL PARAMETERS!
    return BpmEstimator(
      sampleRate: args.sampleRate,
      frameSize: args.frameSize,
      windowSeconds: args.windowSeconds,
      emaAlpha: args.emaAlpha,
      historyLength: args.historyLength,
      minBpm: minBpm,
      maxBpm: maxBpm,
      useSpectralFlux: args.useSpectralFlux,
      onsetSensitivity: args.onsetSensitivity,
      medianFilterSize: args.medianFilterSize,
      adaptiveThresholdRatio: args.adaptiveThresholdRatio,
      hypothesisDecay: args.hypothesisDecay,
      switchThreshold: args.switchThreshold,
      switchHoldFrames: args.switchHoldFrames,
      lockStabilityHi: args.lockStabilityHi,
      lockStabilityLo: args.lockStabilityLo,
      beatsToLock: args.beatsToLock,
      beatsToUnlock: args.beatsToUnlock,
      reportDeadbandUnlocked: args.reportDeadbandUnlocked,
      reportDeadbandLocked: args.reportDeadbandLocked,
      reportQuantUnlocked: args.reportQuantUnlocked,
      reportQuantLocked: args.reportQuantLocked,
      minEnergyDb: args.minEnergyDb,
    );
  }
}