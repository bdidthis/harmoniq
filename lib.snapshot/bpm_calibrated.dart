// lib/bpm_calibrated.dart
// Builder for BpmEstimator with calibration support
// Fixed: Removed non-existent parameters, aligned with actual BpmEstimator constructor

import 'bpm_estimator.dart';
import 'calibration_tools.dart';

class EstimatorBuildArgs {
  final int sampleRate;
  final int frameSize;
  final double windowSeconds;
  final double emaAlpha;
  final int historyLength;

  // Song-optimized parameters
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
    this.switchHoldFrames = 4,
    this.lockStability = 0.78,
    this.unlockStability = 0.62,
    this.reportDeadbandUnlocked = 0.04,
    this.reportDeadbandLocked = 0.20,
    this.reportQuantUnlocked = 0.02,
    this.reportQuantLocked = 0.08,
    this.minEnergyDb = -65.0,
    this.fallbackMinBpm = 60.0,
    this.fallbackMaxBpm = 190.0,
  });
}

class CalibratedEstimator {
  static BpmEstimator fromRecommendation({
    required CalibrateRecommendation rec,
    required EstimatorBuildArgs args,
  }) {
    final double minBpm = (rec.minBpm > 0) ? rec.minBpm : args.fallbackMinBpm;
    final double maxBpm = (rec.maxBpm > 0) ? rec.maxBpm : args.fallbackMaxBpm;

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
      lockStability: args.lockStability,
      unlockStability: args.unlockStability,
      reportDeadbandUnlocked: args.reportDeadbandUnlocked,
      reportDeadbandLocked: args.reportDeadbandLocked,
      reportQuantUnlocked: args.reportQuantUnlocked,
      reportQuantLocked: args.reportQuantLocked,
      minEnergyDb: args.minEnergyDb,
    );
  }
}
