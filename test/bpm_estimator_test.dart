import 'package:test/test.dart';
import 'package:harmoniq/bpm_estimator.dart';

void main() => test(
    'init', () => expect(BpmEstimator().bpm, anyOf(isNull, greaterThan(0))));
