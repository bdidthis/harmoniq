// lib/estimator_factory.dart
// Fixed: Corrected parameter names for lock stability

import 'bpm_estimator.dart';
import 'calibration_tools.dart';
import 'bpm_calibrated.dart';

class EstimatorFactory {
  static BpmEstimator create({
    required int sampleRate,
    int frameSize = 1024,
    double? hintBpm,
    bool tightened = false,
  }) {
    final rec = HintCalibrator(
      hintBpm: hintBpm,
      bandTightness:
          hintBpm == null ? HintBandTightness.loose : HintBandTightness.medium,
      defaultMinBpm: 60,
      defaultMaxBpm: 190,
    ).recommend();

    final args = EstimatorBuildArgs(
      sampleRate: sampleRate,
      frameSize: frameSize,
      windowSeconds: 12.0,
      emaAlpha: 0.12,
      historyLength: 36,
      useSpectralFlux: true,
      onsetSensitivity: 0.9,
      medianFilterSize: 9,
      adaptiveThresholdRatio: 1.7,
      hypothesisDecay: 0.97,
      switchThreshold: 1.35,
      switchHoldFrames: 4,
      lockStabilityHi: 0.78, // ✅ FIXED: was 'lockStability'
      lockStabilityLo: 0.62, // ✅ FIXED: was 'unlockStability'
      beatsToLock: 4.5, // Added: required parameter
      beatsToUnlock: 2.5, // Added: required parameter
      reportDeadbandUnlocked: 0.04,
      reportDeadbandLocked: 0.20,
      reportQuantUnlocked: 0.02,
      reportQuantLocked: 0.08,
      minEnergyDb: -65.0,
      fallbackMinBpm: 60.0,
      fallbackMaxBpm: 190.0,
    );

    if (!tightened) {
      return CalibratedEstimator.fromRecommendation(rec: rec, args: args);
    } else {
      final recTight = HintCalibrator(hintBpm: hintBpm).finalizeTightening(rec);
      return CalibratedEstimator.fromRecommendation(rec: recTight, args: args);
    }
  }
}
