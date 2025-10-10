// lib/key_detector.dart
// Updated with multi-model support, temporal smoothing, and tuning regression

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'tuning.dart';
import 'cqt_chroma.dart';
import 'genre_config.dart';

class KeyAlt {
  final String label;
  final double score;
  const KeyAlt(this.label, this.score);
}

class KeyDetectorConfig {
  final Genre genre;
  final Subgenre subgenre;
  final GenreModelConfig modelConfig;

  const KeyDetectorConfig({
    required this.genre,
    required this.subgenre,
    required this.modelConfig,
  });

  factory KeyDetectorConfig.auto() {
    final manager = GenreConfigManager();
    return KeyDetectorConfig(
      genre: Genre.auto,
      subgenre: Subgenre.none,
      modelConfig: manager.getConfig(),
    );
  }
}

class TemporalSmoother {
  final TemporalSmoothing type;
  final double strength;
  final int windowSize;

  // HMM parameters
  final List<List<double>> _transitionMatrix = [];
  final List<double> _priorProbs = [];

  // DBN parameters
  final List<List<double>> _beliefState = [];

  // History
  final List<List<double>> _history = [];

  TemporalSmoother({
    required this.type,
    required this.strength,
    this.windowSize = 10,
  }) {
    if (type == TemporalSmoothing.hmm) {
      _initializeHMM();
    } else if (type == TemporalSmoothing.dbn) {
      _initializeDBN();
    }
  }

  void _initializeHMM() {
    // Initialize 24x24 transition matrix for key transitions
    for (int i = 0; i < 24; i++) {
      final row = List<double>.filled(24, 0.01);
      row[i] = 0.7; // Self-transition

      // Higher probability for related keys
      final relativeMinor = (i + 9) % 24;
      final relativeMajor = (i + 3) % 24;
      final parallel = i % 2 == 0 ? i + 1 : i - 1;

      if (parallel >= 0 && parallel < 24) row[parallel] = 0.1;
      row[relativeMinor] = 0.08;
      row[relativeMajor] = 0.08;

      _transitionMatrix.add(row);
    }

    // Uniform prior
    _priorProbs.addAll(List<double>.filled(24, 1.0 / 24));
  }

  void _initializeDBN() {
    // Initialize belief network
    for (int i = 0; i < 24; i++) {
      _beliefState.add(List<double>.filled(windowSize, 1.0 / 24));
    }
  }

  List<double> smooth(List<double> currentProbs) {
    if (type == TemporalSmoothing.none) return currentProbs;

    if (type == TemporalSmoothing.ema) {
      return _smoothEMA(currentProbs);
    } else if (type == TemporalSmoothing.hmm) {
      return _smoothHMM(currentProbs);
    } else if (type == TemporalSmoothing.dbn) {
      return _smoothDBN(currentProbs);
    }

    return currentProbs;
  }

  List<double> _smoothEMA(List<double> current) {
    if (_history.isEmpty) {
      _history.add(current);
      return current;
    }

    final previous = _history.last;
    final smoothed = List<double>.filled(current.length, 0.0);

    for (int i = 0; i < current.length; i++) {
      smoothed[i] = strength * previous[i] + (1 - strength) * current[i];
    }

    _history.add(smoothed);
    if (_history.length > windowSize) _history.removeAt(0);

    return smoothed;
  }

  List<double> _smoothHMM(List<double> observation) {
    if (_history.isEmpty) {
      _history.add(observation);
      return observation;
    }

    // Forward algorithm with transition matrix
    final previous = _history.last;
    final smoothed = List<double>.filled(24, 0.0);

    for (int i = 0; i < 24; i++) {
      double sum = 0.0;
      for (int j = 0; j < 24; j++) {
        sum += previous[j] * _transitionMatrix[j][i];
      }
      smoothed[i] = observation[i] * sum;
    }

    // Normalize
    final total = smoothed.reduce((a, b) => a + b);
    if (total > 0) {
      for (int i = 0; i < 24; i++) {
        smoothed[i] =
            smoothed[i] / total * (1 - strength) + observation[i] * strength;
      }
    }

    _history.add(smoothed);
    if (_history.length > windowSize) _history.removeAt(0);

    return smoothed;
  }

  List<double> _smoothDBN(List<double> observation) {
    // Dynamic Bayesian Network smoothing
    if (_beliefState.isEmpty) return observation;

    final smoothed = List<double>.filled(24, 0.0);

    // Update belief state
    for (int i = 0; i < 24; i++) {
      // Shift history
      for (int t = windowSize - 1; t > 0; t--) {
        _beliefState[i][t] = _beliefState[i][t - 1];
      }
      _beliefState[i][0] = observation[i];

      // Compute smoothed value from belief window
      double weightedSum = 0.0;
      double weightSum = 0.0;
      for (int t = 0; t < windowSize; t++) {
        final weight = math.exp(-t * 0.5); // Exponential decay
        weightedSum += _beliefState[i][t] * weight;
        weightSum += weight;
      }

      smoothed[i] = weightSum > 0 ? weightedSum / weightSum : observation[i];
    }

    // Mix with current observation based on strength
    for (int i = 0; i < 24; i++) {
      smoothed[i] = smoothed[i] * strength + observation[i] * (1 - strength);
    }

    return smoothed;
  }

  void reset() {
    _history.clear();
    _beliefState.clear();
    if (type == TemporalSmoothing.dbn) {
      _initializeDBN();
    }
  }
}

class MultiModelKeyDetector {
  final Map<String, Interpreter?> _models = {};
  final Map<String, bool> _modelLoading = {};
  GenreModelConfig? _currentConfig;

  final List<String> _labels = List<String>.generate(24, (i) {
    const pcs = [
      'C',
      'C#',
      'D',
      'D#',
      'E',
      'F',
      'F#',
      'G',
      'G#',
      'A',
      'A#',
      'B',
    ];
    final r = i ~/ 2;
    final isMaj = (i % 2) == 0;
    return '${pcs[r]} ${isMaj ? 'major' : 'minor'}';
  });

  Future<bool> loadModel(String path) async {
    if (_models.containsKey(path)) return _models[path] != null;
    if (_modelLoading[path] == true) return false;

    _modelLoading[path] = true;

    try {
      final interpreter = await Interpreter.fromAsset(path);
      _models[path] = interpreter;
      _modelLoading[path] = false;
      print('Loaded model: $path');
      return true;
    } catch (e) {
      print('Failed to load model $path: $e');
      _models[path] = null;
      _modelLoading[path] = false;
      return false;
    }
  }

  Future<void> switchConfig(GenreModelConfig config) async {
    _currentConfig = config;

    // Load primary model
    await loadModel(config.modelPath);

    // Load fallback if different
    if (config.fallbackPath != config.modelPath) {
      await loadModel(config.fallbackPath);
    }
  }

  (List<double>, double?) inferFromChroma(List<double> chroma) {
    if (_currentConfig == null || chroma.length != 12) {
      return (List<double>.filled(24, 1.0 / 24), null);
    }

    final model = _models[_currentConfig!.modelPath] ??
        _models[_currentConfig!.fallbackPath];

    if (model == null) {
      return (List<double>.filled(24, 1.0 / 24), null);
    }

    try {
      final input = Float32List.fromList(chroma);
      final inputBuffer = input.reshape([1, 12]);

      // Check if model supports tuning regression
      double? tuningOffset;
      if (_currentConfig!.supportsTuningRegression) {
        // Model with dual output (key probs + tuning)
        final keyOutput = List.filled(1, List.filled(24, 0.0));
        final tuningOutput = List.filled(1, List.filled(1, 0.0));
        model.runForMultipleInputs(
          [inputBuffer],
          {0: keyOutput, 1: tuningOutput},
        );

        final probs = List<double>.from(
          keyOutput[0].map((e) => e is double ? e : (e as num).toDouble()),
        );
        tuningOffset =
            (tuningOutput[0][0] as num).toDouble() * 400; // Scale to ±400 cents

        return (_softmax(probs), tuningOffset);
      } else {
        // Standard model (key probs only)
        final output = List.filled(1, List.filled(24, 0.0));
        model.run(inputBuffer, output);

        final probs = List<double>.from(
          output[0].map((e) => e is double ? e : (e as num).toDouble()),
        );

        return (_softmax(probs), null);
      }
    } catch (e) {
      print('Inference error: $e');
      return (List<double>.filled(24, 1.0 / 24), null);
    }
  }

  List<double> _softmax(List<double> x, {double temp = 1.0}) {
    double maxV = -1e9;
    for (final v in x) {
      if (v.isFinite && v > maxV) maxV = v;
    }

    final e = List<double>.filled(x.length, 0.0);
    double sum = 0.0;
    for (int i = 0; i < x.length; i++) {
      if (x[i].isFinite) {
        e[i] = math.exp((x[i] - maxV) / temp);
        sum += e[i];
      }
    }

    if (sum <= 0) return List<double>.filled(x.length, 1.0 / x.length);

    for (int i = 0; i < e.length; i++) {
      e[i] /= sum;
    }
    return e;
  }

  void dispose() {
    for (var model in _models.values) {
      model?.close();
    }
    _models.clear();
    _modelLoading.clear();
  }
}

class KeyDetector {
  // ---------------------- Configuration ----------------------
  final int sampleRate;
  final int fftSize;
  final int hop;
  final double minHz;
  final double maxHz;

  KeyDetectorConfig _config;
  final MultiModelKeyDetector _multiModel = MultiModelKeyDetector();
  late TemporalSmoother _smoother;

  // ---------------------- State ----------------------
  final List<double> _ring = <double>[];
  final List<double> _hpcp = List<double>.filled(12, 0.0);
  final List<double> _hpcpInst = List<double>.filled(12, 0.0);

  List<double> _vizSpectrum = const [];
  double? _peakHz;

  // Results
  String _label = '--';
  double _confidence = 0.0;
  List<KeyAlt> _alternates = const [];
  double? _tuningOffset;

  // Display-stable values
  String _displayLabel = '--';
  double _displayConf = 0.0;
  List<KeyAlt> _displayAlts = const [];
  double? _displayTuning;

  // Lock tracking
  String _lastWinner = '--';
  int _agreeRun = 0;
  int _lockCounter = 0;

  // Classical detector components
  late final List<double> _win;
  late final List<double> _re;
  late final List<double> _im;
  final TuningEstimator _tuner = TuningEstimator();
  late final CqtChroma _cqt;

  // HPSS history
  final List<List<double>> _magHist = <List<double>>[];

  // Beat-synchronous state
  double _beatBpm = 0.0;
  final List<double> _beatAcc = List<double>.filled(12, 0.0);
  double _beatT = 0.0;
  String _beatLabel = '--';
  double _beatConf = 0.0;

  // Logging
  String _modelPath = 'none';
  String _fallbackPath = 'none';

  KeyDetector({
    required this.sampleRate,
    this.fftSize = 4096,
    this.hop = 1024,
    this.minHz = 50.0,
    this.maxHz = 5000.0,
    KeyDetectorConfig? config,
  })  : _config = config ?? KeyDetectorConfig.auto(),
        _cqt = CqtChroma(sampleRate: sampleRate, minHz: minHz, maxHz: maxHz) {
    // Validate parameters
    if (sampleRate <= 0) throw ArgumentError('sampleRate must be positive');
    if (fftSize <= 0 || (fftSize & (fftSize - 1)) != 0) {
      throw ArgumentError('fftSize must be a positive power of two');
    }
    if (hop <= 0) throw ArgumentError('hop must be positive');
    if (minHz >= maxHz) throw ArgumentError('minHz must be less than maxHz');

    // Initialize components
    _win = List<double>.generate(fftSize, (n) {
      if (fftSize <= 1) return 1.0;
      return 0.5 - 0.5 * math.cos(2 * math.pi * n / (fftSize - 1));
    });
    _re = List<double>.filled(fftSize, 0.0);
    _im = List<double>.filled(fftSize, 0.0);

    _smoother = TemporalSmoother(
      type: _config.modelConfig.smoothingType,
      strength: _config.modelConfig.smoothingStrength,
    );

    _initializeModels();
  }

  void _initializeModels() async {
    await GenreConfigManager().initialize();
    await _multiModel.switchConfig(_config.modelConfig);
    _modelPath = _config.modelConfig.modelPath;
    _fallbackPath = _config.modelConfig.fallbackPath;
  }

  // ---------------------- Public API ----------------------
  String get label => _displayLabel;
  double get confidence => _displayConf;
  List<KeyAlt> get topAlternates =>
      List<KeyAlt>.from(_displayAlts, growable: false);
  List<double> get hpcp => List<double>.from(_hpcp, growable: false);
  double? get tuningOffset => _displayTuning;
  String get beatLabel => _beatLabel;
  double get beatConfidence => _beatConf;

  // For logging
  String get modelUsed => _modelPath;
  String get fallbackModel => _fallbackPath;
  GenreModelConfig get currentConfig => _config.modelConfig;

  Future<void> switchGenre(
    Genre genre, {
    Subgenre subgenre = Subgenre.none,
  }) async {
    final manager = GenreConfigManager();
    final newConfig = manager.getConfig(genre: genre, subgenre: subgenre);

    _config = KeyDetectorConfig(
      genre: genre,
      subgenre: subgenre,
      modelConfig: newConfig,
    );

    await _multiModel.switchConfig(newConfig);
    _modelPath = newConfig.modelPath;
    _fallbackPath = newConfig.fallbackPath;

    _smoother = TemporalSmoother(
      type: newConfig.smoothingType,
      strength: newConfig.smoothingStrength,
    );

    reset();
  }

  void setBeatBpm(double bpm) {
    _beatBpm = bpm.isFinite && bpm > 0 ? bpm : 0.0;
  }

  void reset() {
    _ring.clear();
    _magHist.clear();
    for (int i = 0; i < 12; i++) {
      _hpcp[i] = 0.0;
      _hpcpInst[i] = 0.0;
      _beatAcc[i] = 0.0;
    }
    _label = '--';
    _confidence = 0.0;
    _alternates = const [];
    _tuningOffset = null;
    _displayLabel = '--';
    _displayConf = 0.0;
    _displayAlts = const [];
    _displayTuning = null;
    _lastWinner = '--';
    _agreeRun = 0;
    _lockCounter = 0;
    _vizSpectrum = const [];
    _peakHz = null;
    _beatT = 0.0;
    _beatLabel = '--';
    _beatConf = 0.0;
    _smoother.reset();
  }

  // ---------------------- Streaming API ----------------------
  void addBytes(
    Uint8List bytes, {
    required int channels,
    required bool isFloat32,
  }) {
    if (bytes.isEmpty || channels <= 0) return;

    final bd = ByteData.sublistView(bytes);

    if (isFloat32) {
      final count = bytes.length ~/ 4;
      for (int i = 0; i < count; i += channels) {
        double s = 0.0;
        int valid = 0;
        for (int ch = 0; ch < channels; ch++) {
          final idx = 4 * (i + ch);
          if (idx + 3 < bytes.length) {
            final val = bd.getFloat32(idx, Endian.little);
            if (val.isFinite) {
              s += val;
              valid++;
            }
          }
        }
        if (valid > 0) _pushMono(s / valid);
      }
    } else {
      final count = bytes.length ~/ 2;
      for (int i = 0; i < count; i += channels) {
        double s = 0.0;
        int valid = 0;
        for (int ch = 0; ch < channels; ch++) {
          final idx = 2 * (i + ch);
          if (idx + 1 < bytes.length) {
            s += bd.getInt16(idx, Endian.little) / 32768.0;
            valid++;
          }
        }
        if (valid > 0) _pushMono(s / valid);
      }
    }
  }

  void _pushMono(double sample) {
    if (!sample.isFinite) return;

    _ring.add(sample);
    while (_ring.length >= fftSize) {
      final frame = List<double>.from(_ring.getRange(0, fftSize));
      _processFrame(frame);
      final rm = hop.clamp(1, fftSize);
      _ring.removeRange(0, rm);
    }
  }

  // ---------------------- Frame processing ----------------------
  void _processFrame(List<double> frame) {
    if (frame.length != fftSize) return;

    // FFT
    for (int n = 0; n < fftSize; n++) {
      _re[n] = frame[n] * _win[n];
      _im[n] = 0.0;
    }
    _fftRadix2(_re, _im);

    final int half = fftSize >> 1;
    final double binHz = sampleRate / fftSize;

    // Magnitude spectrum with configurable whitening
    final List<double> mag = List<double>.filled(half, 0.0);
    for (int k = 1; k < half; k++) {
      final double r = _re[k], i = _im[k];
      double m = math.sqrt(r * r + i * i);

      // Configurable local whitening
      if (_config.modelConfig.whiteningAlpha > 0) {
        double avg = 1e-9;
        int cnt = 0;
        final windowSize =
            (5 * _config.modelConfig.whiteningAlpha).round().clamp(1, 10);

        for (int j = math.max(1, k - windowSize);
            j <= math.min(half - 1, k + windowSize);
            j++) {
          final rr = _re[j], ii = _im[j];
          avg += math.sqrt(rr * rr + ii * ii);
          cnt++;
        }
        if (cnt > 0) {
          avg /= cnt;
          m = m * (1 - _config.modelConfig.whiteningAlpha) +
              (m / (avg + 1e-9)) * _config.modelConfig.whiteningAlpha;
        }
      }
      mag[k] = m;
    }

    // Harmonic enhancement
    final List<double> enh = List<double>.from(mag);
    for (int k = 1; k < half; k++) {
      final int h2 = k << 1;
      final int h3 = k * 3;
      if (h2 < half) enh[k] += 0.5 * mag[h2];
      if (h3 < half) enh[k] += 0.25 * mag[h3];
    }

    _vizSpectrum = _compactSpectrum(enh, maxBars: 64);

    // HPSS if enabled
    final List<double> harm =
        _config.modelConfig.customParams['use_hpss'] == true
            ? _hpssHarmonic(enh)
            : enh;

    // Configurable bass suppression
    final List<double> weighted = _applyLowFreqWeight(
      harm,
      binHz,
      _config.modelConfig.bassSuppression,
    );

    // Tuning estimation (classical or from model)
    double tuningCents = 0.0;
    if (!_config.modelConfig.supportsTuningRegression) {
      tuningCents = _tuner.estimateCents(weighted, binHz);
    }

    // Chroma extraction with configurable bins
    final List<double> chroma;
    if (_config.modelConfig.hpcpBins > 12) {
      // Use CQT for higher resolution
      chroma = _cqt.chromaFromSpectrum(weighted, binHz, tuningCents);
    } else {
      chroma = _chromaFromSpectrumSimple(
        weighted,
        binHz,
        minHz,
        maxHz,
        tuningCents,
      );
    }

    // Update HPCP
    for (int i = 0; i < 12; i++) {
      final inst = chroma[i];
      if (inst.isFinite) {
        _hpcpInst[i] = inst;
        _hpcp[i] = (1 - 0.2) * _hpcp[i] + 0.2 * inst;
      }
    }

    // Normalize HPCP
    double hpcpSum = 0.0;
    for (final v in _hpcp) {
      hpcpSum += v;
    }
    if (hpcpSum > 0) {
      for (int i = 0; i < 12; i++) {
        _hpcp[i] /= hpcpSum;
      }
    }

    // Get predictions
    _estimateKey();

    // Update display
    _updateStableDisplay();

    // Beat synchronous update
    _updateBeatSynchronous();
  }

  void _estimateKey() {
    // Get ML predictions
    final (mlProbs, mlTuning) = _multiModel.inferFromChroma(_hpcp);

    // Apply temporal smoothing
    final smoothedProbs = _smoother.smooth(mlProbs);

    // Get classical predictions if enabled
    List<double> classicalProbs = List<double>.filled(24, 0.0);
    if (_config.modelConfig.useClassical) {
      classicalProbs = _getClassicalProbs();
    }

    // Combine ML and classical based on weight
    final combinedProbs = List<double>.filled(24, 0.0);
    final mlWeight = 1.0 - _config.modelConfig.classicalWeight;

    for (int i = 0; i < 24; i++) {
      combinedProbs[i] = smoothedProbs[i] * mlWeight +
          classicalProbs[i] * _config.modelConfig.classicalWeight;
    }

    // Normalize
    double sum = combinedProbs.reduce((a, b) => a + b);
    if (sum > 0) {
      for (int i = 0; i < 24; i++) {
        combinedProbs[i] /= sum;
      }
    }

    // Find top candidates
    final candidates = <KeyAlt>[];
    for (int i = 0; i < 24; i++) {
      candidates.add(KeyAlt(_getKeyLabel(i), combinedProbs[i]));
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));

    // Set results
    _label = candidates[0].label;
    _confidence = candidates[0].score;
    _alternates = candidates.take(3).toList();
    _tuningOffset =
        mlTuning ?? _tuner.estimateCents(_hpcp, sampleRate / fftSize);
  }

  List<double> _getClassicalProbs() {
    final probs = List<double>.filled(24, 0.0);

    // Krumhansl-Schmuckler key profiles
    const majorProfile = [
      6.35,
      2.23,
      3.48,
      2.33,
      4.38,
      4.09,
      2.52,
      5.19,
      2.39,
      3.66,
      2.29,
      2.88,
    ];
    const minorProfile = [
      6.33,
      2.68,
      3.52,
      5.38,
      2.60,
      3.53,
      2.54,
      4.75,
      3.98,
      2.69,
      3.34,
      3.17,
    ];

    for (int r = 0; r < 12; r++) {
      // Major key
      double majScore = 0.0;
      double majNorm = 0.0;
      for (int i = 0; i < 12; i++) {
        final idx = (i + r) % 12;
        majScore += _hpcp[idx] * majorProfile[i];
        majNorm += majorProfile[i] * majorProfile[i];
      }
      probs[r * 2] = majScore / math.sqrt(majNorm + 1e-9);

      // Minor key
      double minScore = 0.0;
      double minNorm = 0.0;
      for (int i = 0; i < 12; i++) {
        final idx = (i + r) % 12;
        minScore += _hpcp[idx] * minorProfile[i];
        minNorm += minorProfile[i] * minorProfile[i];
      }
      probs[r * 2 + 1] = minScore / math.sqrt(minNorm + 1e-9);
    }

    // Apply softmax
    return _softmax(probs);
  }

  String _getKeyLabel(int index) {
    const pcs = [
      'C',
      'C#',
      'D',
      'D#',
      'E',
      'F',
      'F#',
      'G',
      'G#',
      'A',
      'A#',
      'B',
    ];
    final r = index ~/ 2;
    final isMaj = (index % 2) == 0;
    return '${pcs[r]} ${isMaj ? 'major' : 'minor'}';
  }

  void _updateStableDisplay() {
    final String cur = _label;
    final double curConf = _confidence;

    // Track agreement
    if (_lastWinner == cur) {
      _agreeRun++;
    } else {
      _lastWinner = cur;
      _agreeRun = 1;
    }

    // Lock logic with configurable thresholds
    bool shouldUpdate = false;

    if (curConf >= _config.modelConfig.minConfidence && cur != '--') {
      _lockCounter++;
      if (_lockCounter >= _config.modelConfig.lockFrames) {
        shouldUpdate = true;
      }
    } else {
      _lockCounter = math.max(0, _lockCounter - 1);
    }

    if (shouldUpdate || _displayLabel == '--') {
      _displayLabel = cur;
      _displayConf = curConf;
      _displayAlts = _alternates;
      _displayTuning = _tuningOffset;
    }
  }

  void _updateBeatSynchronous() {
    if (_beatBpm <= 0) return;

    final double dt = hop / sampleRate;
    for (int i = 0; i < 12; i++) {
      _beatAcc[i] += _hpcpInst[i];
    }
    _beatT += dt;

    final double period = 60.0 / _beatBpm;
    if (_beatT >= period) {
      double s = 0.0;
      for (final v in _beatAcc) {
        s += v;
      }
      if (s > 0) {
        final List<double> bs = List<double>.filled(12, 0.0);
        for (int i = 0; i < 12; i++) {
          bs[i] = _beatAcc[i] / s;
        }

        // Run inference on beat-aligned chroma
        final (probs, _) = _multiModel.inferFromChroma(bs);
        int bestIdx = 0;
        double bestProb = probs[0];
        for (int i = 1; i < 24; i++) {
          if (probs[i] > bestProb) {
            bestProb = probs[i];
            bestIdx = i;
          }
        }

        _beatLabel = _getKeyLabel(bestIdx);
        _beatConf = bestProb;
      }

      for (int i = 0; i < 12; i++) {
        _beatAcc[i] = 0.0;
      }
      _beatT = _beatT - period;
    }
  }

  // ---------------------- Helper methods ----------------------
  List<double> _applyLowFreqWeight(
    List<double> spec,
    double binHz,
    double cutHz,
  ) {
    final int n = spec.length;
    final List<double> out = List<double>.filled(n, 0.0);
    for (int k = 0; k < n; k++) {
      final double f = k * binHz;
      final double w = f >= cutHz ? 1.0 : math.pow(f / cutHz, 2.0).toDouble();
      out[k] = spec[k] * w;
    }
    return out;
  }

  List<double> _hpssHarmonic(List<double> cur) {
    final int n = cur.length;
    _magHist.add(cur);
    while (_magHist.length > 9) {
      _magHist.removeAt(0);
    }
    if (_magHist.length < 5) return cur;

    final List<double> out = List<double>.filled(n, 0.0);
    for (int k = 1; k < n; k++) {
      final double mh = _medianTimeAtBin(k);
      final double mp = _medianFreqAt(cur, k);
      final double mask = mh / (mh + mp + 1e-9);
      out[k] = cur[k] * mask;
    }
    return out;
  }

  double _medianTimeAtBin(int bin) {
    if (_magHist.isEmpty || bin < 0) return 0.0;

    final int t = _magHist.length;
    final List<double> vals = List<double>.filled(t, 0.0);
    for (int i = 0; i < t; i++) {
      if (bin < _magHist[i].length) {
        vals[i] = _magHist[i][bin];
      }
    }
    vals.sort();
    final int m = t >> 1;
    if ((t & 1) == 1) return vals[m];
    return 0.5 * (vals[m - 1] + vals[m]);
  }

  double _medianFreqAt(List<double> cur, int k) {
    const int w = 7;
    final int lo = math.max(1, k - (w >> 1));
    final int hi = math.min(cur.length - 1, k + (w >> 1));
    final int len = hi - lo + 1;
    if (len <= 0) return 0.0;

    final List<double> vals = List<double>.filled(len, 0.0);
    int p = 0;
    for (int i = lo; i <= hi; i++) {
      if (i < cur.length) {
        vals[p++] = cur[i];
      }
    }
    if (p == 0) return 0.0;

    final List<double> slice = vals.sublist(0, p)..sort();
    final int m = p >> 1;
    if ((p & 1) == 1) return slice[m];
    return p > 1 ? 0.5 * (slice[m - 1] + slice[m]) : slice[0];
  }

  static List<double> _compactSpectrum(
    List<double> full, {
    required int maxBars,
  }) {
    if (full.isEmpty) return const [];
    final int half = full.length;
    final int bars = math.min(maxBars, half);
    if (bars <= 0) return const [];

    final int step = (half / bars).floor().clamp(1, half);
    final List<double> out = List<double>.filled(bars, 0.0);
    int o = 0;
    for (int i = 0; i < half && o < bars; i += step, o++) {
      double sum = 0.0;
      int c = 0;
      for (int j = i; j < i + step && j < half; j++) {
        sum += full[j];
        c++;
      }
      out[o] = c > 0 ? sum / c : 0.0;
    }
    double mx = 1e-12;
    for (final v in out) {
      if (v > mx) mx = v;
    }
    return out.map((v) => (v / mx).clamp(0.0, 1.0)).toList(growable: false);
  }

  static List<double> _chromaFromSpectrumSimple(
    List<double> spec,
    double binHz,
    double minHz,
    double maxHz,
    double cents,
  ) {
    final List<double> chroma = List<double>.filled(12, 0.0);
    const double ln2 = 0.6931471805599453;
    for (int k = 1; k < spec.length; k++) {
      final double f = k * binHz;
      if (f < minHz || f > maxHz || !f.isFinite) continue;
      final double midi = 69 + 12 * (math.log(f / 440.0) / ln2) + cents / 100.0;
      int pc = midi.round() % 12;
      if (pc < 0) pc += 12;
      chroma[pc] += spec[k];
    }
    double sum = 0.0;
    for (final v in chroma) {
      sum += v;
    }
    if (sum > 0)
      for (int i = 0; i < 12; i++) {
        chroma[i] /= sum;
      }
    return chroma;
  }

  static List<double> _softmax(List<double> logits, {double scale = 1.0}) {
    if (logits.isEmpty) return const [];

    double m = logits[0] * scale;
    for (int i = 1; i < logits.length; i++) {
      final v = logits[i] * scale;
      if (v > m) m = v;
    }
    double sum = 0.0;
    final List<double> e = List<double>.filled(logits.length, 0.0);
    for (int i = 0; i < logits.length; i++) {
      final li = logits[i];
      if (li.isFinite) {
        final ev = math.exp(li * scale - m);
        e[i] = ev;
        sum += ev;
      }
    }
    if (sum <= 0) {
      final p = 1.0 / logits.length;
      return List<double>.filled(logits.length, p);
    }
    for (int i = 0; i < logits.length; i++) {
      e[i] = e[i] / sum;
    }
    return e;
  }

  void _fftRadix2(List<double> re, List<double> im) {
    final n = re.length;
    if (n != im.length || n <= 0) return;

    int j = 0;
    for (int i = 0; i < n; i++) {
      if (i < j) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
      int m = n >> 1;
      while (m >= 1 && j >= m) {
        j -= m;
        m >>= 1;
      }
      j += m;
    }

    for (int len = 2; len <= n; len <<= 1) {
      final half = len >> 1;
      final theta = -2.0 * math.pi / len;
      final wpr = math.cos(theta);
      final wpi = math.sin(theta);
      for (int i = 0; i < n; i += len) {
        double wr = 1.0, wi = 0.0;
        for (int k = 0; k < half; k++) {
          final i0 = i + k;
          final i1 = i0 + half;
          if (i1 < n) {
            final tr = wr * re[i1] - wi * im[i1];
            final ti = wr * im[i1] + wi * re[i1];
            re[i1] = re[i0] - tr;
            im[i1] = im[i0] - ti;
            re[i0] += tr;
            im[i0] += ti;
          }
          final tmp = wr;
          wr = tmp * wpr - wi * wpi;
          wi = tmp * wpi + wi * wpr;
        }
      }
    }
  }

  void dispose() {
    _multiModel.dispose();
  }
}
