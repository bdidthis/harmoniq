// lib/bpm_estimator.dart
// HarmoniQ BPM Estimator — v6.3 "Enhanced Anti-Halftime + Full Parameter Support"
//
// FIXES:
// - Constructor now accepts ALL parameters (no more ignored args)
// - Expanded anti-halftime range: 55-95 BPM (was 70-95)
// - More aggressive thresholds for half-tempo correction
// - Runs anti-halftime BEFORE hypothesis selection
// - Added musical tempo priors throughout

import 'dart:math' as math;
import 'dart:typed_data';

class BpmEstimate {
  final double bpm;
  final double stability; // 0..1
  final bool isLocked;
  final double confidence; // 0..1
  const BpmEstimate(this.bpm, this.stability, this.isLocked, this.confidence);
}

class _FftResult {
  final List<double> real;
  final List<double> imag;
  _FftResult(this.real, this.imag);
}

class _KalmanFilter {
  double _estimate = 0.0;
  double _errorCovariance = 1.0;
  double update(
      double measurement, double processNoise, double measurementNoise) {
    _errorCovariance += processNoise;
    final k = _errorCovariance / (_errorCovariance + measurementNoise);
    _estimate = _estimate + k * (measurement - _estimate);
    _errorCovariance = (1 - k) * _errorCovariance;
    return _estimate;
  }

  void reset(double value) {
    _estimate = value;
    _errorCovariance = 1.0;
  }
}

class BpmEstimator {
  double? get bpm => _last.bpm > 0 ? _last.bpm : null;
  double get stability => _last.stability;
  bool get isLocked => _last.isLocked;
  double get confidence => _last.confidence;

  Map<String, dynamic> get debugStats => <String, dynamic>{
    'env_len': _onsetCurve.length,
    'energy_db': _energyDb,
    'written_frames': _envelopesWritten,
    'window_frames': _framesPerWindow,
    'last_frame_rms': _lastFrameRms,
    'format_guess': _formatGuess,
    'hypotheses': {
      'h1_bpm': _h1Bpm,
      'h1_score': _h1Score,
      'h2_bpm': _h2Bpm,
      'h2_score': _h2Score,
      'h3_bpm': _h3Bpm,
      'h3_score': _h3Score,
    },
    'last_acf_top': _lastAcfTop,
    'octave_history': _octaveHistory,
    'recent_candidates': _recentCandidates.length,
    'sticky_target': _stickyTarget,
    'active_clamp_target': _activeClampTarget,
  };

  final int sampleRate;
  final int frameSize;
  final double windowSeconds;

  final double emaAlpha;
  final int historyLength;

  final double minBpm;
  final double maxBpm;

  final bool useSpectralFlux;
  final double onsetSensitivity;
  final int medianFilterSize;
  final double adaptiveThresholdRatio;
  final bool enableWhitening;

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

  final double rescueTolStrong;
  final double rescueTolWeak;

  final bool useKalmanFilter;

  final double stickyHoldFracLocked;
  final double stickyHoldFracUnlocked;
  final double stickyConfidenceThreshold;
  final int stickyMinFrames;

  final bool metronomeClampEnabled;
  final List<double> metronomeTargets;
  final double metronomeClampRadius;
  final double metronomeCandidateRadius;
  final double metronomeMinScore;

  late final int _framesPerWindow;
  final List<double> _frame = <double>[];
  final List<double> _hann;
  final List<double> _onsetCurve = <double>[];
  final List<double> _onsetHist = <double>[];
  final List<double> _bpmHist = <double>[];

  final List<double> _prevMag;
  final List<double> _smoothMag;

  double _h1Bpm = 0.0, _h1Score = 0.0;
  double _h2Bpm = 0.0, _h2Score = 0.0;
  double _h3Bpm = 0.0, _h3Score = 0.0;
  int _switchHold = 0;

  double _emaBpm = 0.0;
  double _reportedBpm = 0.0;
  int _envelopesWritten = 0;
  List<Map<String, double>> _lastAcfTop = <Map<String, double>>[];

  BpmEstimate _last = const BpmEstimate(0.0, 0.0, false, 0.0);
  double _lastFrameRms = 0.0;
  double _energyDb = -120.0;
  String _formatGuess = 'pcm16';

  final List<double> _octaveHistory = <double>[];
  static const int _octaveHistorySize = 24;
  final List<List<double>> _recentCandidates = <List<double>>[];

  int _lockGoodFrames = 0;
  int _lockBadFrames = 0;

  double? _stickyTarget;
  int _stickyFrames = 0;

  final _KalmanFilter _kalman = _KalmanFilter();
  double? _activeClampTarget;

  // ENHANCED CONSTRUCTOR - Now accepts ALL parameters
  BpmEstimator({
    required this.sampleRate,
    this.frameSize = 1024,
    this.windowSeconds = 12.0,
    this.emaAlpha = 0.15,
    this.historyLength = 24,
    this.minBpm = 60.0,
    this.maxBpm = 190.0,
    this.useSpectralFlux = true,
    this.onsetSensitivity = 0.9,
    this.medianFilterSize = 9,
    this.adaptiveThresholdRatio = 1.7,
    this.enableWhitening = true,
    this.hypothesisDecay = 0.97,
    this.switchThreshold = 1.35,
    this.switchHoldFrames = 4,
    this.lockStabilityHi = 0.82,
    this.lockStabilityLo = 0.58,
    this.beatsToLock = 4.5,
    this.beatsToUnlock = 2.5,
    this.reportDeadbandUnlocked = 0.04,
    this.reportDeadbandLocked = 0.12,
    this.reportQuantUnlocked = 0.05,
    this.reportQuantLocked = 0.05,
    this.minEnergyDb = -65.0,
    this.rescueTolStrong = 0.025,
    this.rescueTolWeak = 0.04,
    this.useKalmanFilter = false,
    this.stickyHoldFracLocked = 0.08,
    this.stickyHoldFracUnlocked = 0.05,
    this.stickyConfidenceThreshold = 0.75,
    this.stickyMinFrames = 12,
    this.metronomeClampEnabled = false,
    this.metronomeTargets = const [83.1, 92.3, 103.5, 120.0],
    this.metronomeClampRadius = 1.5,
    this.metronomeCandidateRadius = 2.0,
    this.metronomeMinScore = 0.90,
  })  : _hann = List<double>.generate(
    frameSize,
        (int n) => frameSize <= 1
        ? 1.0
        : (0.5 - 0.5 * math.cos(2 * math.pi * n / (frameSize - 1))),
  ),
        _prevMag = List<double>.filled(frameSize ~/ 2 + 1, 0.0),
        _smoothMag = List<double>.filled(frameSize ~/ 2 + 1, 1e-3) {
    if (sampleRate <= 0) throw ArgumentError('sampleRate must be positive');
    if (frameSize <= 0 || (frameSize & (frameSize - 1)) != 0) {
      throw ArgumentError('frameSize must be a positive power of 2');
    }
    if (minBpm >= maxBpm) throw ArgumentError('minBpm < maxBpm required');
    _framesPerWindow =
        math.max(32, (windowSeconds * sampleRate / frameSize).round());
  }

  // Convenience: explicit metronome-mode builder
  factory BpmEstimator.forMetronome({
    required int sampleRate,
    List<double> targets = const [83.1, 92.3, 103.5, 120.0],
  }) {
    return BpmEstimator(
      sampleRate: sampleRate,
      metronomeClampEnabled: true,
      metronomeTargets: targets,
    );
  }

  void reset() {
    _frame.clear();
    _onsetCurve.clear();
    _onsetHist.clear();
    _bpmHist.clear();
    _prevMag.fillRange(0, _prevMag.length, 0.0);
    _smoothMag.fillRange(0, _smoothMag.length, 1e-3);
    _octaveHistory.clear();
    _recentCandidates.clear();

    _h1Bpm = 0.0;
    _h1Score = 0.0;
    _h2Bpm = 0.0;
    _h2Score = 0.0;
    _h3Bpm = 0.0;
    _h3Score = 0.0;
    _switchHold = 0;

    _emaBpm = 0.0;
    _reportedBpm = 0.0;
    _envelopesWritten = 0;
    _lastAcfTop = <Map<String, double>>[];

    _last = const BpmEstimate(0.0, 0.0, false, 0.0);
    _lastFrameRms = 0.0;
    _energyDb = -120.0;
    _formatGuess = 'pcm16';

    _lockGoodFrames = 0;
    _lockBadFrames = 0;
    _stickyTarget = null;
    _stickyFrames = 0;
    _kalman.reset(0.0);
    _activeClampTarget = null;
  }

  void addBytes(Uint8List bytes,
      {required int channels, required bool isFloat32}) {
    if (bytes.isEmpty || channels <= 0) return;

    _formatGuess = isFloat32 ? 'float32' : 'pcm16';
    final ByteData bd = ByteData.sublistView(bytes);
    double frameEnergy = 0.0;
    int processedSamples = 0;

    if (isFloat32) {
      final int count = bytes.length ~/ 4;
      for (int i = 0; i < count; i += channels) {
        double s = 0.0;
        for (int ch = 0; ch < channels; ch++) {
          final int idx = 4 * (i + ch);
          if (idx + 3 < bytes.length) s += bd.getFloat32(idx, Endian.little);
        }
        s /= channels;
        if (s.isFinite) {
          frameEnergy += s * s;
          processedSamples++;
          _pushSample(s);
        }
      }
    } else {
      final int count = bytes.length ~/ 2;
      for (int i = 0; i < count; i += channels) {
        double s = 0.0;
        for (int ch = 0; ch < channels; ch++) {
          final int idx = 2 * (i + ch);
          if (idx + 1 < bytes.length)
            s += bd.getInt16(idx, Endian.little) / 32768.0;
        }
        s /= channels;
        if (s.isFinite) {
          frameEnergy += s * s;
          processedSamples++;
          _pushSample(s);
        }
      }
    }

    if (processedSamples > 0) {
      _lastFrameRms = math.sqrt(frameEnergy / processedSamples);
      _energyDb =
      _lastFrameRms > 0 ? 20 * math.log(_lastFrameRms) / math.ln10 : -120.0;
    }
  }

  void _pushSample(double s) {
    _frame.add(s);
    if (_frame.length >= frameSize) {
      _processFrame();
      _frame.clear();
    }
  }

  void _processFrame() {
    if (_frame.isEmpty) return;

    final List<double> win = List<double>.filled(frameSize, 0.0);
    for (int i = 0; i < frameSize; i++) {
      final double x = (i < _frame.length) ? _frame[i] : 0.0;
      win[i] = x * _hann[i];
    }

    double onset = 0.0;
    if (useSpectralFlux) {
      final _FftResult f = _fft(win);
      final int half = frameSize ~/ 2;
      const double alpha = 0.95;
      for (int k = 1; k <= half; k++) {
        final double mag =
        math.sqrt(f.real[k] * f.real[k] + f.imag[k] * f.imag[k]);
        if (enableWhitening) {
          _smoothMag[k] = alpha * _smoothMag[k] + (1 - alpha) * mag;
          final double whiten = (mag / (_smoothMag[k] + 1e-9)) - 1.0;
          final double diff = whiten > 0 ? whiten : 0.0;
          onset += diff * _staticOnsetWeight(k * sampleRate / frameSize);
        } else {
          double diff = mag - _prevMag[k];
          if (diff < 0) diff = 0.0;
          onset += diff * _staticOnsetWeight(k * sampleRate / frameSize);
        }
        _prevMag[k] = mag;
      }
      onset /= (half > 0 ? half.toDouble() : 1.0);
    } else {
      double acc = 0.0;
      for (int i = 0; i < frameSize; i++) {
        final double v = win[i];
        acc += v * v;
      }
      onset = math.sqrt(acc / frameSize);
    }

    _onsetHist.add(onset);
    if (_onsetHist.length > 120) _onsetHist.removeAt(0);

    double thr = 0.0;
    if (_onsetHist.length >= medianFilterSize) {
      final List<double> tmp = List<double>.from(_onsetHist)..sort();
      final double median = tmp[tmp.length ~/ 2];
      thr = median * adaptiveThresholdRatio;
    }
    final double post = math.max(0.0, onset - thr) * onsetSensitivity;

    _onsetCurve.add(post);
    _envelopesWritten++;
    while (_onsetCurve.length > _framesPerWindow) _onsetCurve.removeAt(0);

    if (_energyDb < minEnergyDb) return;
    if (_onsetCurve.length < 48) return;

    _estimateTempo();
  }

  double _staticOnsetWeight(double freq) {
    double w = 1.0;
    if (freq >= 150 && freq < 400)
      w = 1.8;
    else if (freq >= 400 && freq < 1200)
      w = 1.5;
    else if (freq >= 60 && freq < 150)
      w = 1.2;
    else if (freq >= 1200) w = 0.8;
    return w;
  }

  // Helper: max ACF support near a BPM (reads _lastAcfTop)
  double _acfSupportNear(double bpm, {double radius = 1.25}) {
    if (bpm <= 0 || _lastAcfTop.isEmpty) return 0.0;
    double best = 0.0;
    for (final m in _lastAcfTop) {
      final b = m['bpm'] ?? 0.0;
      final s = m['score'] ?? 0.0;
      if ((b - bpm).abs() <= radius) {
        if (s > best) best = s;
      }
    }
    return best;
  }

  void _estimateTempo() {
    final int n = _onsetCurve.length;
    if (n < 48) return;

    final int minLag =
    math.max(2, (60.0 * sampleRate / (frameSize * maxBpm)).round());
    final int maxLag =
    math.min(n - 3, (60.0 * sampleRate / (frameSize * minBpm)).round());
    if (minLag >= maxLag) return;

    final Map<int, double> acf = <int, double>{};
    _lastAcfTop = <Map<String, double>>[];
    for (int lag = minLag; lag <= maxLag; lag++) {
      acf[lag] = _acfNormWeighted(_onsetCurve, lag, lambda: 0.98);
    }

    final Map<int, double> enhanced = <int, double>{};
    acf.forEach((lag, score) {
      double boost = score;
      final int lagHalf = lag ~/ 2;
      if (acf.containsKey(lagHalf) && (acf[lagHalf]! > 0.25)) boost += 0.10;
      for (final mult in [2, 3, 4]) {
        final int harmLag = lag * mult;
        if (acf.containsKey(harmLag)) {
          final strength = acf[harmLag]!;
          if (strength > 0.15) boost += 0.08 * (mult == 2 ? 1.5 : 1.0);
        }
      }
      enhanced[lag] = boost;
    });

    final List<MapEntry<int, double>> sorted = enhanced.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (sorted.isEmpty) return;

    final List<double> candidates = <double>[];
    final List<double> candScores = <double>[];
    final int keep = math.min(12, sorted.length);

    for (int i = 0; i < keep; i++) {
      final int lag = sorted[i].key;
      final double refined =
      _parabolicRefinePeak(enhanced, lag, minLag, maxLag);
      final double bpm = 60.0 / (refined * frameSize / sampleRate);
      final double totalScore = sorted[i].value;
      _lastAcfTop.add({'lag': refined, 'bpm': bpm, 'score': totalScore});
      candidates.add(bpm);
      candScores.add(totalScore);
    }

    _recentCandidates
        .add(candidates.sublist(0, math.min(8, candidates.length)));
    if (_recentCandidates.length > 5) _recentCandidates.removeAt(0);

    // ===== ENHANCED ANTI-HALFTIME - RUNS BEFORE HYPOTHESIS SELECTION =====
    // This is CRITICAL: fix candidates BEFORE they become hypotheses
    for (int i = 0; i < candidates.length; i++) {
      final double cand = candidates[i];

      // EXPANDED RANGE: 55-95 BPM (catches Calvin Harris at 64, Nirvana at 65)
      if (cand >= 55.0 && cand <= 95.0) {
        final double dbl = (cand * 2.0).clamp(minBpm, maxBpm);

        if (dbl >= 100.0 && dbl <= maxBpm) {
          final double selfAcf = _acfSupportNear(cand);
          final double dblAcf = _acfSupportNear(dbl);
          final bool dblInCands = candidates.any((c) => (c - dbl).abs() <= 2.0);

          // MUCH MORE AGGRESSIVE THRESHOLDS
          double threshold = 0.45; // Default: promote if double is 45% as strong

          // Even more aggressive in specific cases
          if (dblInCands) threshold = 0.35; // Double tempo in top candidates
          if (candScores[i] < 0.50) threshold = 0.30; // Low confidence on half-tempo
          if (cand >= 60.0 && cand <= 67.0) threshold = 0.25; // Classic half-tempo zone

          // Promote to double if evidence supports it
          if (dblAcf >= selfAcf * threshold) {
            candidates[i] = dbl;
            // Also boost the score since we're correcting an error
            candScores[i] = candScores[i] * 1.15;
          }
        }
      }
    }
    // ===== END ANTI-HALFTIME =====

    _h1Score *= hypothesisDecay;
    _h2Score *= hypothesisDecay;
    _h3Score *= hypothesisDecay;

    for (int i = 0; i < candidates.length; i++) {
      final double bpm = candidates[i];
      final double score = candScores[i];
      bool matched = false;
      if (_sameFamily(bpm, _h1Bpm)) {
        _h1Bpm = _blendTempo(_h1Bpm, _h1Score, bpm, score);
        _h1Score += score * 0.6;
        matched = true;
      } else if (_sameFamily(bpm, _h2Bpm)) {
        _h2Bpm = _blendTempo(_h2Bpm, _h2Score, bpm, score);
        _h2Score += score * 0.6;
        matched = true;
      } else if (_sameFamily(bpm, _h3Bpm)) {
        _h3Bpm = _blendTempo(_h3Bpm, _h3Score, bpm, score);
        _h3Score += score * 0.6;
        matched = true;
      }
      if (!matched) {
        if (_h3Score <= _h2Score && _h3Score <= _h1Score) {
          _h3Bpm = bpm;
          _h3Score = score;
        } else if (_h2Score <= _h1Score) {
          _h2Bpm = bpm;
          _h2Score = score;
        } else {
          _h1Bpm = bpm;
          _h1Score = score;
        }
      }
    }

    if (_h2Score > _h1Score) {
      final tb = _h1Bpm, ts = _h1Score;
      _h1Bpm = _h2Bpm;
      _h1Score = _h2Score;
      _h2Bpm = tb;
      _h2Score = ts;
    }
    if (_h3Score > _h2Score) {
      final tb = _h2Bpm, ts = _h2Score;
      _h2Bpm = _h3Bpm;
      _h2Score = _h3Score;
      _h3Bpm = tb;
      _h3Score = ts;
    }

    if (_h2Score > _h1Score * switchThreshold) {
      _switchHold++;
      if (_switchHold >= switchHoldFrames) {
        final tb = _h1Bpm, ts = _h1Score;
        _h1Bpm = _h2Bpm;
        _h1Score = _h2Score;
        _h2Bpm = tb;
        _h2Score = ts;
        _switchHold = 0;
      }
    } else {
      if (_switchHold > 0) _switchHold--;
    }

    double selected = (_h1Bpm > 0.0)
        ? _h1Bpm
        : (candidates.isNotEmpty ? candidates.first : 0.0);

    // Additional musical tempo prior: prefer 100-180 range when uncertain
    if (selected > 0 && selected < 92.0) {
      final double alt = (selected * 2.0).clamp(minBpm, maxBpm);
      final double selAcf = _acfSupportNear(selected);
      final double altAcf = _acfSupportNear(alt);

      // If double lands in "reasonable" range and has decent support
      if (alt >= 100.0 && alt <= 180.0 && altAcf >= selAcf * 0.70) {
        selected = alt;
      }
    }

    final double total = math.max(1e-9, _h1Score + _h2Score + _h3Score);
    double conf = _h1Score / total;
    if (_h2Score > 0) {
      final double prominence = (_h1Score - _h2Score) / _h2Score;
      if (prominence > 2.0) conf = (conf * 1.15).clamp(0.0, 1.0);
      if (prominence > 4.0) conf = (conf * 1.10).clamp(0.0, 1.0);
    }
    if (_octaveHistory.length >= 8) {
      final recent = _octaveHistory.sublist(_octaveHistory.length - 8);
      final median = _computeMedian(recent);
      if (median > 0) {
        final deviations =
        recent.map((v) => (v - median).abs() / median).toList();
        final avgDev = deviations.reduce((a, b) => a + b) / recent.length;
        if (avgDev < 0.03) conf = (conf * 1.15).clamp(0.0, 1.0);
      }
    }
    final strongCandidates = candScores.where((s) => s > total * 0.3).length;
    if (strongCandidates > 4) conf = (conf * 0.85).clamp(0.0, 1.0);

    bool clampLocked = false;
    if (metronomeClampEnabled) {
      final double? clamped = _tryMetronomeClamp(selected, candidates, conf);
      if (clamped != null) {
        selected = clamped;
        conf = math.max(conf, 0.92);
        clampLocked = true;
      }
    }

    if (!clampLocked) {
      selected = _octaveRescue(selected, candidates, conf);
    }

    if (_emaBpm == 0.0) {
      _emaBpm = selected;
    } else {
      final double diff = (selected - _emaBpm).abs();
      double alpha = emaAlpha;
      if (diff > 6.0)
        alpha = (emaAlpha * 1.8).clamp(emaAlpha, 0.30).toDouble();
      else if (diff > 3.0)
        alpha = (emaAlpha * 1.3).clamp(emaAlpha, 0.22).toDouble();
      _emaBpm = _emaBpm * (1 - alpha) + selected * alpha;
    }

    _bpmHist.add(_emaBpm);
    while (_bpmHist.length > historyLength) _bpmHist.removeAt(0);

    final double stab = _stabilityMAD(_bpmHist);
    final double tempoChange = _detectTempoChange(_bpmHist);
    if (tempoChange > 0.02) {
      _lockGoodFrames = math.max(0, _lockGoodFrames - 2);
    }

    final double refBpm = _emaBpm > 0 ? _emaBpm : 100.0;
    final int dynLockFrames =
    math.max(8, (_bpmToLag(refBpm) * beatsToLock).round());
    final int dynUnlockFrames =
    math.max(4, (_bpmToLag(refBpm) * beatsToUnlock).round());

    bool isLockedNow = _last.isLocked;
    if (clampLocked) {
      _lockGoodFrames++;
      _lockBadFrames = 0;
      if (_lockGoodFrames >= 12) isLockedNow = true;
    } else if (stab >= lockStabilityHi && conf >= 0.60) {
      _lockGoodFrames++;
      _lockBadFrames = 0;
      if (_lockGoodFrames >= dynLockFrames) isLockedNow = true;
    } else if (stab <= lockStabilityLo) {
      _lockBadFrames++;
      _lockGoodFrames = 0;
      if (_lockBadFrames >= dynUnlockFrames) isLockedNow = false;
    } else {
      if (_lockGoodFrames > 0) _lockGoodFrames--;
      if (_lockBadFrames > 0) _lockBadFrames--;
    }

    double outInternal = _applyStickyTarget(_emaBpm, conf, isLockedNow);

    if (useKalmanFilter) {
      final double processNoise = isLockedNow ? 0.005 : 0.03;
      final double measurementNoise =
      isLockedNow ? 0.05 : (1.0 - conf) * 1.5 + 0.1;
      outInternal = _kalman.update(outInternal, processNoise, measurementNoise);
    }

    final double deadband =
    _lagFracToBpmRadius(outInternal, isLockedNow ? reportDeadbandLocked : reportDeadbandUnlocked);
    double out = outInternal;
    if (_reportedBpm > 0 && (out - _reportedBpm).abs() < deadband)
      out = _reportedBpm;

    final double q = isLockedNow ? reportQuantLocked : reportQuantUnlocked;
    out = (out / q).round() * q;
    _reportedBpm = out;

    _last = BpmEstimate(out, stab, isLockedNow, conf.clamp(0.0, 1.0));
  }

  double _acfNormWeighted(List<double> x, int lag, {double lambda = 0.98}) {
    if (lag <= 0 || lag >= x.length) return 0.0;
    double s = 0.0, n1 = 0.0, n2 = 0.0;
    final int m = x.length - lag;
    for (int i = 0; i < m; i++) {
      final double w = math.pow(lambda, (m - i - 1)).toDouble();
      final double a = x[i] * w;
      final double b = x[i + lag] * w;
      s += a * b;
      n1 += a * a;
      n2 += b * b;
    }
    final double denom = math.sqrt(math.max(1e-12, n1 * n2));
    return (denom > 0.0) ? (s / denom) : 0.0;
  }

  double _parabolicRefinePeak(
      Map<int, double> acf, int lag, int minLag, int maxLag) {
    if (lag <= minLag || lag >= maxLag) return lag.toDouble();
    final double y0 = acf[lag - 1] ?? 0.0;
    final double y1 = acf[lag] ?? 0.0;
    final double y2 = acf[lag + 1] ?? 0.0;
    if (y1 <= y0 || y1 <= y2) return lag.toDouble();
    final double denom = (y0 - 2.0 * y1 + y2);
    if (denom.abs() < 1e-9) return lag.toDouble();
    final double delta = 0.5 * (y0 - y2) / denom;
    if (delta.abs() > 0.5) return lag.toDouble();
    return lag + delta;
  }

  double _octaveRescue(double bpm, List<double> candidates, double confidence) {
    if (bpm <= 0) return bpm;
    final double ref = (_octaveHistory.length >= 5)
        ? _computeMedian(_octaveHistory)
        : (_emaBpm > 0 ? _emaBpm : bpm);
    if (!ref.isFinite || ref <= 0) return bpm;

    final double ratio = bpm / ref;
    final double tol = (confidence >= 0.75) ? rescueTolStrong : rescueTolWeak;

    final List<({double mult, double target})> fam = [
      (mult: 0.5, target: bpm * 2.0),
      (mult: 2.0, target: bpm * 0.5),
      (mult: 0.667, target: bpm * 1.5),
      (mult: 1.5, target: bpm * 0.667),
    ];

    double original = bpm;
    for (final cand in fam) {
      final double diff = (ratio - cand.mult).abs();
      if (diff <= tol) {
        final double corrected = cand.target.clamp(minBpm, maxBpm);
        int support = 0;
        final int frames = _recentCandidates.length;
        for (final frameCands in _recentCandidates) {
          final double rad = corrected * 0.05;
          for (final v in frameCands) {
            if ((v - corrected).abs() <= rad) {
              support++;
              break;
            }
          }
        }
        if (frames == 0 || support >= (frames * 0.6)) {
          bpm = corrected;
          break;
        }
      }
    }

    if (confidence >= 0.65 || (bpm - original).abs() < 0.1) {
      _octaveHistory.add(bpm);
      if (_octaveHistory.length > _octaveHistorySize)
        _octaveHistory.removeAt(0);
    }
    return bpm;
  }

  double? _tryMetronomeClamp(
      double selected, List<double> candidates, double confidence) {
    _activeClampTarget = null;
    double? bestTarget;
    double bestScore = -1.0;

    bool near(double v, double t, double r) => (v - t).abs() <= r;

    double _acfSupportFor(double t, {double tight = 1.2}) {
      final hits = _lastAcfTop.where((m) {
        final cb = m['bpm'] ?? 0.0;
        return (cb - t).abs() <= tight;
      });
      if (hits.isEmpty) return 0.0;
      return hits.map((m) => m['score'] ?? 0.0).reduce(math.max);
    }

    bool _hasCandidateNear(double t, {double r = 1.2}) {
      for (final c in candidates) {
        if ((c - t).abs() <= r) return true;
      }
      return false;
    }

    for (final t in metronomeTargets) {
      double score = -1.0;

      if (near(selected, t, metronomeClampRadius)) score = 0.90;
      if (_hasCandidateNear(t, r: metronomeCandidateRadius))
        score = math.max(score, 0.86);

      for (final c in candidates) {
        final bool isHalfOrDouble =
            near(c * 2.0, t, metronomeCandidateRadius) ||
                near(c * 0.5, t, metronomeCandidateRadius);
        if (isHalfOrDouble) {
          final double acfTop = _acfSupportFor(t);
          if (acfTop > 0.50) score = math.max(score, 0.86);
        }
      }

      final double acfTop = _acfSupportFor(t);
      if (acfTop > 0.0) score = math.max(score, math.min(1.0, 0.5 + acfTop));

      if (t == 120.0) {
        final bool near120Band = (selected >= 116.0 && selected <= 123.0);
        final bool near60Band = (selected >= 58.5 && selected <= 61.5);
        final bool cand120 = _hasCandidateNear(120.0, r: 1.4);
        final bool cand60 = _hasCandidateNear(60.0, r: 1.0);
        final double acf120 = _acfSupportFor(120.0, tight: 1.4);
        if ((near120Band || near60Band) &&
            (acf120 > 0.42 || cand120 || cand60)) {
          score = math.max(score, 0.965);
        }
      }

      if (score >= metronomeMinScore && score > bestScore) {
        bestScore = score;
        bestTarget = t;
      }
    }

    if (bestTarget != null) _activeClampTarget = bestTarget;
    return bestTarget;
  }

  double _applyStickyTarget(double bpm, double confidence, bool isLocked) {
    if (_stickyTarget != null && confidence < stickyConfidenceThreshold) {
      _stickyTarget = null;
      _stickyFrames = 0;
    }
    if (_stickyTarget != null) {
      final double holdRad = _lagFracToBpmRadius(
          bpm, isLocked ? stickyHoldFracLocked : stickyHoldFracUnlocked);
      if ((bpm - _stickyTarget!).abs() <= holdRad) {
        _stickyFrames++;
        return _stickyTarget!;
      }
      _stickyTarget = null;
      _stickyFrames = 0;
    }
    if (isLocked &&
        confidence >= stickyConfidenceThreshold &&
        _bpmHist.length >= stickyMinFrames) {
      final List<double> tail =
      _bpmHist.sublist(_bpmHist.length - stickyMinFrames);
      final double mean = tail.reduce((a, b) => a + b) / tail.length;
      final double meanRad = _lagFracToBpmRadius(mean, 0.02);
      bool tight = true;
      for (final v in tail) {
        if ((v - mean).abs() > meanRad) {
          tight = false;
          break;
        }
      }
      if (tight && _stickyTarget == null) {
        _stickyTarget = mean;
        _stickyFrames = 1;
        return mean;
      }
    }
    return bpm;
  }

  double _stabilityMAD(List<double> series) {
    if (series.length < 6) return 0.0;
    final int use = math.min(16, series.length);
    final List<double> tail = series.sublist(series.length - use);
    final double median = _computeMedian(tail);
    if (!median.isFinite || median <= 0) return 0.0;
    final deviations = tail.map((v) => (v - median).abs()).toList()..sort();
    final double mad = _computeMedian(deviations);
    final double nmad = (mad / median).abs();
    double stab = math.exp(-nmad * 25.0);
    if (series.length >= 8) {
      final recent4 = series.sublist(series.length - 4);
      final double m4 = recent4.reduce((a, b) => a + b) / 4.0;
      double v4 = 0.0;
      for (final v in recent4) {
        final d = v - m4;
        v4 += d * d;
      }
      v4 /= 4.0;
      if (v4 > mad * mad * 4.0) stab = math.min(stab, 0.45);
    }
    return stab.clamp(0.0, 1.0);
  }

  double _detectTempoChange(List<double> series) {
    if (series.length < 8) return 0.0;
    final tail = series.sublist(series.length - 8);
    double maxDiff = 0.0;
    for (int i = 1; i < tail.length; i++) {
      maxDiff = math.max(maxDiff, (tail[i] - tail[i - 1]).abs());
    }
    final double median = _computeMedian(tail);
    return median > 0 ? maxDiff / median : 0.0;
  }

  double _framesPerSecond() => sampleRate / frameSize;

  double _bpmToLag(double bpm) {
    if (!bpm.isFinite || bpm <= 0) return 0.0;
    final fps = _framesPerSecond();
    if (!fps.isFinite || fps <= 0) return 0.0;
    return (60.0 / bpm) * fps;
  }

  double _lagToBpm(double lag) {
    if (!lag.isFinite || lag <= 0) return 0.0;
    final fps = _framesPerSecond();
    if (!fps.isFinite || fps <= 0) return 0.0;
    return 60.0 / (lag / fps);
  }

  double _lagFracToBpmRadius(double bpm, double frac) {
    final double lag = _bpmToLag(bpm);
    final double lo = _lagToBpm(lag * (1.0 + frac));
    final double hi = _lagToBpm(lag * (1.0 - frac));
    return ((hi - bpm).abs() + (bpm - lo).abs()) * 0.5;
  }

  double _computeMedian(List<double> values) {
    if (values.isEmpty) return 0.0;
    final sorted = List<double>.from(values)..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  _FftResult _fft(List<double> input) {
    final int n = input.length;
    final List<double> real = List<double>.from(input);
    final List<double> imag = List<double>.filled(n, 0.0);
    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      while ((j & bit) != 0) {
        j &= ~bit;
        bit >>= 1;
      }
      j |= bit;
      if (i < j) {
        final double tr = real[i];
        real[i] = real[j];
        real[j] = tr;
        final double ti = imag[i];
        imag[i] = imag[j];
        imag[j] = ti;
      }
    }
    for (int len = 2; len <= n; len <<= 1) {
      final double ang = -2 * math.pi / len;
      final double wlenR = math.cos(ang);
      final double wlenI = math.sin(ang);
      for (int i = 0; i < n; i += len) {
        double wR = 1.0, wI = 0.0;
        for (int k = 0; k < len ~/ 2; k++) {
          final int u = i + k;
          final int v = i + k + len ~/ 2;
          final double tR = real[v] * wR - imag[v] * wI;
          final double tI = real[v] * wI + imag[v] * wR;
          real[v] = real[u] - tR;
          imag[v] = imag[u] - tI;
          real[u] += tR;
          imag[u] += tI;
          final double nWR = wR * wlenR - wI * wlenI;
          final double nWI = wR * wlenI + wI * wlenR;
          wR = nWR;
          wI = nWI;
        }
      }
    }
    return _FftResult(real, imag);
  }

  bool _sameFamily(double a, double b) {
    if (!(a > 0.0 && b > 0.0)) return false;
    final double r = (a > b) ? (a / b) : (b / a);
    return (r > 0.98 && r < 1.02) ||
        (r > 1.95 && r < 2.05) ||
        (r > 2.90 && r < 3.10);
  }

  double _blendTempo(
      double base, double baseScore, double add, double addScore) {
    final double w1 = math.max(1e-9, baseScore);
    final double w2 = math.max(1e-9, addScore);
    return (base * w1 + add * w2) / (w1 + w2);
  }
}