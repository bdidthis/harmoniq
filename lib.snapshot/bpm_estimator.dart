// lib/bpm_estimator.dart
// HarmoniQ BPM Estimator – v2.6.0 "Harmonic Promotion v2"
// - Uses ACF-map-based harmonic promotion to avoid half-time collapse on metronomes
// - Keeps triple-hypothesis tracker, anti-snap filter, same public API

import 'dart:math' as math;
import 'dart:typed_data';

class BpmEstimate {
  final double bpm; // 0 if unknown
  final double stability; // 0..1
  final bool isLocked;
  final double confidence; // 0..1 (winner hypothesis weight)
  const BpmEstimate(this.bpm, this.stability, this.isLocked, this.confidence);
}

class _FftResult {
  final List<double> real;
  final List<double> imag;
  _FftResult(this.real, this.imag);
}

class BpmEstimator {
  // -------- Public API --------
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
      };

  // -------- Tunables (song-friendly defaults) --------
  final int sampleRate;
  final int frameSize; // power of 2 (e.g. 1024)
  final double windowSeconds; // ACF window (sec)
  final double emaAlpha; // smoothing of reported tempo
  final int historyLength; // for stability calc
  final double minBpm;
  final double maxBpm;

  // Onset (spectral flux)
  final bool useSpectralFlux; // keep true for songs
  final double onsetSensitivity; // 0..1 scale on post-threshold onset
  final int medianFilterSize; // for adaptive threshold
  final double adaptiveThresholdRatio; // >1.0 (how far above median)

  // Tempo tracker (triple hypotheses)
  final double hypothesisDecay; // 0..1 slow decay
  final double switchThreshold; // h2 must beat h1 by this factor to switch
  final int switchHoldFrames; // debounce frames

  // Lock/Report
  final double lockStability; // stability threshold to lock
  final double unlockStability; // hysteresis
  final double reportDeadbandUnlocked;
  final double reportDeadbandLocked;
  final double reportQuantUnlocked;
  final double reportQuantLocked;

  // Energy gate (ignore very quiet)
  final double minEnergyDb;

  // -------- Internal state --------
  late final int _framesPerWindow;
  final List<double> _frame = <double>[];
  final List<double> _hann;
  final List<double> _onsetCurve = <double>[];
  final List<double> _onsetHist = <double>[];
  final List<double> _bpmHist = <double>[];

  // Spectral flux memory
  final List<double> _prevMag;

  // Hypotheses
  double _h1Bpm = 0.0, _h1Score = 0.0;
  double _h2Bpm = 0.0, _h2Score = 0.0;
  double _h3Bpm = 0.0, _h3Score = 0.0;
  int _switchHold = 0;

  // Running state
  double _emaBpm = 0.0;
  double _reportedBpm = 0.0;
  int _envelopesWritten = 0;
  List<Map<String, double>> _lastAcfTop = <Map<String, double>>[];

  BpmEstimate _last = const BpmEstimate(0.0, 0.0, false, 0.0);
  double _lastFrameRms = 0.0;
  double _energyDb = -120.0;
  String _formatGuess = 'pcm16';

  // Anti-snap filter for 83.5/103.5 BPM issue
  final List<double> _snapFilter = [];
  static const int _snapFilterSize = 5;
  static const double _snapThreshold = 0.5;

  BpmEstimator({
    required this.sampleRate,
    this.frameSize = 1024,
    this.windowSeconds = 12.0, // songs: a bit longer
    this.emaAlpha = 0.12,
    this.historyLength = 36,
    this.minBpm = 60.0,
    this.maxBpm = 190.0,
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
  })  : _hann = List<double>.generate(
          frameSize,
          (int n) => frameSize <= 1
              ? 1.0
              : (0.5 - 0.5 * math.cos(2 * math.pi * n / (frameSize - 1))),
        ),
        _prevMag = List<double>.filled(frameSize ~/ 2 + 1, 0.0) {
    if (sampleRate <= 0) {
      throw ArgumentError('sampleRate must be positive');
    }
    if (frameSize <= 0 || (frameSize & (frameSize - 1)) != 0) {
      throw ArgumentError('frameSize must be a positive power of 2');
    }
    if (minBpm >= maxBpm) {
      throw ArgumentError('minBpm < maxBpm required');
    }
    _framesPerWindow = math.max(
      32,
      (windowSeconds * sampleRate / frameSize).round(),
    );
  }

  // -------- Lifecycle --------
  void reset() {
    _frame.clear();
    _onsetCurve.clear();
    _onsetHist.clear();
    _bpmHist.clear();
    _prevMag.fillRange(0, _prevMag.length, 0.0);
    _snapFilter.clear();

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
  }

  // -------- Streaming ingestion --------
  void addBytes(
    Uint8List bytes, {
    required int channels,
    required bool isFloat32,
  }) {
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
          if (idx + 3 < bytes.length) {
            s += bd.getFloat32(idx, Endian.little);
          }
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
          if (idx + 1 < bytes.length) {
            s += bd.getInt16(idx, Endian.little) / 32768.0;
          }
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

  // -------- Per-frame processing --------
  void _processFrame() {
    if (_frame.isEmpty) return;

    // Window for FFT
    final List<double> win = List<double>.filled(frameSize, 0.0);
    for (int i = 0; i < frameSize; i++) {
      final double x = (i < _frame.length) ? _frame[i] : 0.0;
      win[i] = x * _hann[i];
    }

    // Onset via spectral flux (weighted for percussion bands)
    double onset = 0.0;
    if (useSpectralFlux) {
      final _FftResult f = _fft(win);
      final int half = frameSize ~/ 2;
      for (int k = 1; k <= half; k++) {
        final double mag = math.sqrt(
          f.real[k] * f.real[k] + f.imag[k] * f.imag[k],
        );
        double diff = mag - _prevMag[k];
        if (diff < 0) diff = 0.0;
        final double freq = k * sampleRate / frameSize;
        double w = 1.0;
        if (freq >= 60 && freq <= 250) {
          w = 1.5; // kick band
        } else if (freq >= 200 && freq <= 900) {
          w = 1.2; // snare/mid
        }
        onset += diff * w;
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

    // Adaptive median threshold
    _onsetHist.add(onset);
    if (_onsetHist.length > 120) {
      _onsetHist.removeAt(0);
    }

    double thr = 0.0;
    if (_onsetHist.length >= medianFilterSize) {
      final List<double> tmp = List<double>.from(_onsetHist)..sort();
      final double median = tmp[tmp.length ~/ 2];
      thr = median * adaptiveThresholdRatio;
    }
    final double post = math.max(0.0, onset - thr) * onsetSensitivity;

    _onsetCurve.add(post);
    _envelopesWritten++;
    while (_onsetCurve.length > _framesPerWindow) {
      _onsetCurve.removeAt(0);
    }

    // Guards
    if (_energyDb < minEnergyDb) return;
    if (_onsetCurve.length < 48) return;

    _estimateTempo();
  }

  // -------- Tempo Estimation --------
  void _estimateTempo() {
    final int n = _onsetCurve.length;
    if (n < 48) return;

    // Lag range (in frames)
    final int minLag = math.max(
      2,
      (60.0 * sampleRate / (frameSize * maxBpm)).round(),
    );
    final int maxLag = math.min(
      n - 3,
      (60.0 * sampleRate / (frameSize * minBpm)).round(),
    );
    if (minLag >= maxLag) return;

    // Normalized ACF
    final Map<int, double> acf = <int, double>{};
    _lastAcfTop = <Map<String, double>>[];
    for (int lag = minLag; lag <= maxLag; lag++) {
      acf[lag] = _acfNorm(_onsetCurve, lag);
    }

    // Pick top peaks by score
    final List<MapEntry<int, double>> sorted = acf.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (sorted.isEmpty) return;

    // Extract best few with parabolic refine + octave support
    final List<double> candidates = <double>[];
    final List<double> candScores = <double>[];
    final int keep = math.min(6, sorted.length);
    for (int i = 0; i < keep; i++) {
      final int lag = sorted[i].key;
      final double refined = _parabolicRefine(acf, lag, minLag, maxLag);
      final double bpm = 60.0 / (refined * frameSize / sampleRate);

      // Neighbor (octave) support score: consider x0.5, x2
      double support = 0.0;
      for (final double r in const [0.5, 2.0]) {
        final int h = (refined * r).round();
        if (h >= minLag && h <= maxLag) {
          final double v = acf[h] ?? 0.0;
          support += v * (r == 0.5 ? 0.7 : 0.5);
        }
      }

      final double totalScore = sorted[i].value + support;
      _lastAcfTop.add({'lag': refined, 'bpm': bpm, 'score': totalScore});
      candidates.add(bpm);
      candScores.add(totalScore);
    }

    // Hypothesis update (decay then fit)
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

    // Re-rank
    if (_h2Score > _h1Score) {
      final double tb = _h1Bpm, ts = _h1Score;
      _h1Bpm = _h2Bpm;
      _h1Score = _h2Score;
      _h2Bpm = tb;
      _h2Score = ts;
    }
    if (_h3Score > _h2Score) {
      final double tb = _h2Bpm, ts = _h2Score;
      _h2Bpm = _h3Bpm;
      _h2Score = _h3Score;
      _h3Bpm = tb;
      _h3Score = ts;
    }

    // Winner / switching debounce
    if (_h2Score > _h1Score * switchThreshold) {
      _switchHold++;
      if (_switchHold >= switchHoldFrames) {
        final double tb = _h1Bpm, ts = _h1Score;
        _h1Bpm = _h2Bpm;
        _h1Score = _h2Score;
        _h2Bpm = tb;
        _h2Score = ts;
        _switchHold = 0;
      }
    } else {
      if (_switchHold > 0) _switchHold--;
    }

    // Select winner (pre-harmonic-promotion)
    double selected = (_h1Bpm > 0.0)
        ? _h1Bpm
        : (candidates.isNotEmpty ? candidates.first : 0.0);
    final double total = math.max(1e-9, _h1Score + _h2Score + _h3Score);
    final double conf = math.max(0.0, math.min(1.0, _h1Score / total));

    // -------- Harmonic Promotion v2 (ACF-map based) --------
    // Promote half-time to 1x when both are strong in the *actual* ACF map.
    double promoteUsingAcf(double bpm, {double tolPct = 0.03}) {
      if (bpm <= 0) return bpm;

      double strengthAt(double targetBpm) {
        if (targetBpm < minBpm || targetBpm > maxBpm) return 0.0;
        // Convert BPM -> lag (floating), then sample ACF around that lag with parabolic refine
        final double lagF = 60.0 / (targetBpm * (frameSize / sampleRate));
        final int lagI = lagF.round();
        if (lagI < 2 || lagI >= _onsetCurve.length - 2) return 0.0;

        // Gather a tiny neighborhood
        final Map<int, double> local = {
          lagI - 1: acf[lagI - 1] ?? 0.0,
          lagI: acf[lagI] ?? 0.0,
          lagI + 1: acf[lagI + 1] ?? 0.0,
        };
        final double refinedLag = _parabolicRefine(
          local,
          lagI,
          lagI - 1,
          lagI + 1,
        );
        final int rl = refinedLag.round().clamp(2, _onsetCurve.length - 2);
        return acf[rl] ?? 0.0;
      }

      final double sSel = strengthAt(bpm);
      final double sDbl = strengthAt(bpm * 2.0);
      final double sHalf = strengthAt(bpm * 0.5);

      // If selected is low family (< 88 BPM), prefer 2x when it's close in strength.
      if (bpm < 88.0 && (bpm * 2.0) <= maxBpm) {
        if (sDbl >= sSel * 0.75 || sDbl > sSel) {
          return bpm * 2.0;
        }
      }

      // If selected is high family (> 176 would exceed default range, so skip),
      // or if we accidentally latched on double-time, allow demotion when 1/2 is much stronger.
      if (bpm > 150.0 && (bpm * 0.5) >= minBpm) {
        if (sHalf >= sSel * 1.25) {
          return bpm * 0.5;
        }
      }

      return bpm;
    }

    selected = promoteUsingAcf(selected);

    // Anti-snap filter for 83.5/103.5 BPM issue
    selected = _applyAntiSnapFilter(selected);

    // Adaptive EMA (faster if far)
    if (_emaBpm == 0.0) {
      _emaBpm = selected;
    } else {
      final double diff = (selected - _emaBpm).abs();
      double alpha = emaAlpha;
      if (diff > 6.0) alpha = (emaAlpha * 1.8).clamp(emaAlpha, 0.28);
      _emaBpm = _emaBpm * (1 - alpha) + selected * alpha;
    }

    // Stability from history (CV-based)
    _bpmHist.add(_emaBpm);
    while (_bpmHist.length > historyLength) {
      _bpmHist.removeAt(0);
    }
    final double stab = _stabilityFromCV(_bpmHist);

    // Lock
    int lockRun = _last.isLocked ? 1 : 0;
    final bool meets = (stab >= lockStability) && (conf >= 0.60);
    final bool drops = (stab < unlockStability);
    bool isLockedNow = _last.isLocked;

    if (!isLockedNow && meets) {
      isLockedNow = true;
    } else if (isLockedNow && drops) {
      isLockedNow = false;
    }
    if (isLockedNow) lockRun++;

    // Reporting quantization/deadband
    double out = _emaBpm;
    final double dead =
        isLockedNow ? reportDeadbandLocked : reportDeadbandUnlocked;
    if (_reportedBpm > 0 && (out - _reportedBpm).abs() < dead) {
      out = _reportedBpm;
    }
    final double q = isLockedNow ? reportQuantLocked : reportQuantUnlocked;
    out = (out / q).round() * q;
    _reportedBpm = out;

    _last = BpmEstimate(out, stab, isLockedNow, conf);
  }

  // Anti-snap filter for problematic BPM values
  double _applyAntiSnapFilter(double bpm) {
    if (bpm <= 0) return bpm;
    final List<double> problemValues = [83.5, 103.5];
    for (final problem in problemValues) {
      if ((bpm - problem).abs() < _snapThreshold) {
        _snapFilter.add(bpm);
        if (_snapFilter.length > _snapFilterSize) {
          _snapFilter.removeAt(0);
        }
        if (_snapFilter.length >= _snapFilterSize) {
          bool allNearProblem = true;
          for (final v in _snapFilter) {
            if ((v - problem).abs() >= _snapThreshold) {
              allNearProblem = false;
              break;
            }
          }
          if (allNearProblem) {
            if (problem * 2 <= maxBpm) return problem * 2;
            if (problem / 2 >= minBpm) return problem / 2;
          }
        }
      }
    }
    return bpm;
  }

  // -------- Math helpers --------
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

  double _acfNorm(List<double> x, int lag) {
    if (lag <= 0 || lag >= x.length) return 0.0;
    double s = 0.0, n1 = 0.0, n2 = 0.0;
    final int m = x.length - lag;
    for (int i = 0; i < m; i++) {
      final double a = x[i];
      final double b = x[i + lag];
      s += a * b;
      n1 += a * a;
      n2 += b * b;
    }
    final double denom = math.sqrt(math.max(1e-12, n1 * n2));
    return (denom > 0.0) ? (s / denom) : 0.0;
  }

  double _parabolicRefine(
    Map<int, double> acf,
    int lag,
    int minLag,
    int maxLag,
  ) {
    double refined = lag.toDouble();
    if (lag <= minLag || lag >= maxLag) return refined;
    final double y0 = acf[lag - 1] ?? 0.0;
    final double y1 = acf[lag] ?? 0.0;
    final double y2 = acf[lag + 1] ?? 0.0;
    if (y1 <= y0 || y1 <= y2) return refined;
    final double denom = (y0 - 2.0 * y1 + y2);
    if (denom.abs() < 1e-9) return refined;
    final double delta = 0.5 * (y0 - y2) / denom;
    if (delta.abs() <= 0.5) {
      refined = lag + delta;
    }
    return refined;
  }

  bool _sameFamily(double a, double b) {
    if (!(a > 0.0 && b > 0.0)) return false;
    final double r = (a > b) ? (a / b) : (b / a);
    // same / double / triple-ish tolerance
    return (r > 0.98 && r < 1.02) ||
        (r > 1.95 && r < 2.05) ||
        (r > 2.90 && r < 3.10);
  }

  double _blendTempo(
    double base,
    double baseScore,
    double add,
    double addScore,
  ) {
    final double w1 = math.max(1e-9, baseScore);
    final double w2 = math.max(1e-9, addScore);
    return (base * w1 + add * w2) / (w1 + w2);
  }

  double _stabilityFromCV(List<double> series) {
    if (series.length < 6) return 0.0;
    final int use = math.min(16, series.length);
    final List<double> tail = series.sublist(series.length - use);
    double sum = 0.0;
    for (int i = 0; i < tail.length; i++) {
      sum += tail[i];
    }
    final double mean = sum / tail.length;
    if (!(mean > 0.0)) return 0.0;

    double varAcc = 0.0;
    for (int i = 0; i < tail.length; i++) {
      final double d = tail[i] - mean;
      varAcc += d * d;
    }
    final double std = math.sqrt(varAcc / tail.length);
    final double cv = std / mean; // 0..∞

    // map to 0..1 (lower cv → higher stability)
    const double k = 18.0; // slope
    final double s = math.exp(-cv * k);
    return s.clamp(0.0, 1.0);
  }
}
