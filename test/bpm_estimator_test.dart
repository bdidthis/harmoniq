// test/bpm_estimator_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:harmoniq_clean_run/bpm_estimator.dart'; // ✅ CORRECT: Package import

void main() {
  test('BpmEstimator initializes with valid sample rate', () {
    final estimator = BpmEstimator(sampleRate: 44100);
    expect(estimator.bpm, isNull);
  });

  test('BpmEstimator starts with zero BPM', () {
    final estimator = BpmEstimator(sampleRate: 44100);
    expect(estimator.bpm, isNull);
    expect(estimator.stability, equals(0.0));
    expect(estimator.isLocked, isFalse);
    expect(estimator.confidence, equals(0.0));
  });

  test('BpmEstimator can be reset', () {
    final estimator = BpmEstimator(sampleRate: 44100);
    estimator.reset();
    expect(estimator.bpm, isNull);
    expect(estimator.stability, equals(0.0));
  });
}