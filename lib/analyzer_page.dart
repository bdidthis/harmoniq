// lib/analyzer_page.dart
// HarmoniQ Analyzer — v3.0 "Conditional Smoothing + Enhanced Correction"
//
// FIXES APPLIED:
// - Conditional wobble prevention (allows corrections from half-tempo zone)
// - Simplified resolver (removed conflicting corrections)
// - Better display throttle (more responsive)
// - Consistent lock thresholds with estimator
// - Single bounds check (removed redundant validation)
// - Pre-lock validation to prevent locking on wrong tempo
// - Audio session options correctly using bitwise OR (original was correct)

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';

import 'bpm_calibrated.dart';
import 'bpm_estimator.dart';
import 'calibration_tools.dart';
import 'genre_config.dart';
import 'key_detector.dart';
import 'logger.dart';
import 'music_math.dart';
import 'paid_tools_page.dart' show PaidToolsPage;
import 'settings_page.dart';
import 'system_audio_page.dart';

extension NumCast on num {
  double get asDouble => toDouble();
  int get asInt => toInt();
}

const double kGlobalBpmBiasPct = 0.0;

class AnalyzerPage extends StatefulWidget {
  const AnalyzerPage({super.key});
  @override
  State<AnalyzerPage> createState() => _AnalyzerPageState();
}

class _AnalyzerPageState extends State<AnalyzerPage> {
  final AudioRecorder _rec = AudioRecorder();
  AudioSession? _audioSession;

  StreamSubscription<RecordState>? _stateSub;
  StreamSubscription<Uint8List>? _audioSub;

  late BpmEstimator _bpm;
  late KeyDetector _key;

  double _rms = 0.0;
  double _peak = 0.0;
  double _rmsDb = -120.0;

  // Energy tracking for beat validation (currently unused, but reserved for future)
  final List<double> _rmsHistory = [];
  static const int _rmsHistorySize = 100;

  final TextEditingController _bpmCtrl = TextEditingController();
  final FocusNode _bpmFocus = FocusNode();
  final List<DateTime> _taps = [];
  double? _displayBpm;
  DateTime _lastDisplayUpdate = DateTime.now();
  int _framesSinceLastUpdate = 0;

  // Slightly more responsive smoothing window
  static const int _bpmSmoothWindowMin = 7;  // Was 9
  static const int _bpmSmoothWindowMax = 15; // Was 21
  final List<double> _bpmHistory = [];

  bool _recording = false;
  int _channels = 1;
  int _sampleRate = 44100;

  String? _lastError;
  AppSettings _settings = AppSettings.defaults();

  final ValueNotifier<double?> _liveBpm = ValueNotifier<double?>(null);

  final TextEditingController _hintCtrl = TextEditingController(text: "120");
  bool _useHint = false;
  bool _useTight = false;

  Genre _selectedGenre = Genre.auto;
  Subgenre _selectedSubgenre = Subgenre.none;

  final HarmoniQLogger _logger = HarmoniQLogger();
  String _currentTestId = '';
  DateTime _testStartTime = DateTime.now();
  int _frameCount = 0;
  int _droppedFrames = 0;

  bool _autoTrapApplied = false;

  @override
  void initState() {
    super.initState();
    _initializeLogger();
    _buildAnalyzers(sampleRate: _sampleRate);
    _initAudio();
  }

  Future<void> _initializeLogger() async {
    await _logger.initialize(enableConsole: true, enableFile: true);
    await GenreConfigManager().initialize();
  }

  @override
  void dispose() {
    _audioSub?.cancel();
    _stateSub?.cancel();
    _rec.dispose();
    _bpmCtrl.dispose();
    _bpmFocus.dispose();
    _hintCtrl.dispose();
    _liveBpm.dispose();
    _key.dispose();
    _logger.close();
    super.dispose();
  }

  Future<void> _initAudio() async {
    try {
      _audioSession = await AudioSession.instance;
      await _audioSession?.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          // CORRECT: Use bitwise OR for audio_session package
          avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.defaultToSpeaker |
          AVAudioSessionCategoryOptions.allowBluetooth,
          avAudioSessionMode: AVAudioSessionMode.measurement,
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.voiceCommunication,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
          androidWillPauseWhenDucked: false,
        ),
      );
    } catch (e) {
      debugPrint('Audio session config error: $e');
    }
  }

  double? get _hintBpm => _useHint ? double.tryParse(_hintCtrl.text.trim()) : null;

  void _buildAnalyzers({required int sampleRate}) {
    _key = KeyDetector(
      sampleRate: sampleRate,
      fftSize: _settings.fftSize,
      hop: _settings.hop,
      minHz: _settings.minHz,
      maxHz: _settings.maxHz,
    );

    final double? hintBpm = _hintBpm;

    final rec = HintCalibrator(
      hintBpm: hintBpm,
      bandTightness:
      hintBpm == null ? HintBandTightness.loose : HintBandTightness.medium,
      defaultMinBpm: _settings.minBpm,
      defaultMaxBpm: _settings.maxBpm,
    ).recommend();

    // ===== ENHANCED ESTIMATOR BUILD ARGS (now properly passed through) =====
    final args = EstimatorBuildArgs(
      sampleRate: sampleRate,
      frameSize: 1024,
      windowSeconds: 12.0,
      emaAlpha: 0.08,
      historyLength: 50,
      useSpectralFlux: true,
      onsetSensitivity: 0.85,
      medianFilterSize: 5,
      adaptiveThresholdRatio: 1.60,
      hypothesisDecay: 0.96,
      switchThreshold: 1.75,
      switchHoldFrames: 12,
      lockStabilityHi: 0.88, // CONSISTENT with UI expectations
      lockStabilityLo: 0.50,
      beatsToLock: 4.5,
      beatsToUnlock: 2.5,
      reportDeadbandUnlocked: 0.03,
      reportDeadbandLocked: 0.12,
      reportQuantUnlocked: 0.02,
      reportQuantLocked: 0.05,
      minEnergyDb: -60.0,
      fallbackMinBpm: _settings.minBpm,
      fallbackMaxBpm: _settings.maxBpm,
    );

    final recToUse =
    _useTight ? HintCalibrator(hintBpm: hintBpm).finalizeTightening(rec) : rec;

    _bpm = CalibratedEstimator.fromRecommendation(rec: recToUse, args: args);
  }

  Future<void> _onGenreChanged(Genre? genre) async {
    if (genre == null) return;
    setState(() {
      _selectedGenre = genre;
      _autoTrapApplied = false;
    });
    await _key.switchGenre(genre, subgenre: _selectedSubgenre);
  }

  Future<void> _onSubgenreChanged(Subgenre? subgenre) async {
    if (subgenre == null) return;
    setState(() {
      _selectedSubgenre = subgenre;
      _autoTrapApplied = true;
    });
    await _key.switchGenre(_selectedGenre, subgenre: subgenre);
  }

  Future<bool> _ensureMicPermission() async {
    var status = await Permission.microphone.status;
    if (status.isGranted) return true;

    if (status.isDenied || status.isRestricted) {
      status = await Permission.microphone.request();
      if (status.isGranted) return true;
    }

    if (await _rec.hasPermission()) return true;

    if (status.isPermanentlyDenied && mounted) {
      setState(() => _lastError = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
          const Text('Microphone access needed. Open Settings to enable.'),
          action: SnackBarAction(label: 'Settings', onPressed: openAppSettings),
          duration: const Duration(seconds: 5),
        ),
      );
    } else if (mounted) {
      setState(() => _lastError = 'Microphone permission required');
    }
    return false;
  }

  Future<void> _startRecording() async {
    if (_recording) return;
    setState(() => _lastError = null);

    final ok = await _ensureMicPermission();
    if (!ok) return;

    try {
      await _audioSession?.setActive(true);
    } catch (e) {
      debugPrint('Audio session activation error: $e');
    }

    _currentTestId = 'test_${DateTime.now().millisecondsSinceEpoch}';
    _testStartTime = DateTime.now();
    _frameCount = 0;
    _droppedFrames = 0;
    _rmsHistory.clear();

    final configs = <RecordConfig>[
      const RecordConfig(
          encoder: AudioEncoder.pcm16bits, sampleRate: 44100, numChannels: 1),
      const RecordConfig(
          encoder: AudioEncoder.pcm16bits, sampleRate: 48000, numChannels: 1),
      const RecordConfig(
          encoder: AudioEncoder.pcm16bits, sampleRate: 32000, numChannels: 1),
    ];

    bool started = false;
    Stream<Uint8List>? audioStream;

    for (final cfg in configs) {
      try {
        audioStream = await _rec.startStream(cfg);
        _channels = cfg.numChannels;
        if (_sampleRate != cfg.sampleRate) {
          _sampleRate = cfg.sampleRate;
          _buildAnalyzers(sampleRate: _sampleRate);
        }
        started = true;
        break;
      } catch (_) {}
    }

    if (!started || audioStream == null) {
      if (mounted) {
        setState(() => _lastError = 'Could not start microphone stream');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start microphone stream')),
        );
      }
      try {
        await _audioSession?.setActive(false);
      } catch (_) {}
      return;
    }

    _stateSub?.cancel();
    _stateSub = _rec.onStateChanged().listen((_) {});

    _audioSub?.cancel();
    _audioSub = audioStream.listen(
          (bytes) {
        try {
          if (bytes.isEmpty) return;
          Uint8List b = ((bytes.length & 1) == 1)
              ? bytes.sublist(0, bytes.length - 1)
              : bytes;
          if (b.isEmpty) return;
          if (b.offsetInBytes != 0) {
            b = Uint8List.fromList(b);
          }
          _processAudioBytes(b);
          _frameCount++;
        } catch (e) {
          _droppedFrames++;
          if (mounted) setState(() => _lastError = 'Frame error: $e');
        }
      },
      onError: (_) => _droppedFrames++,
    );

    setState(() => _recording = true);
  }

  Future<void> _stopRecording() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    try {
      await _rec.stop();
    } catch (_) {}

    try {
      await _audioSession?.setActive(false);
    } catch (_) {}

    await _logTestResult();
    setState(() => _recording = false);
  }

  Future<void> _logTestResult() async {
    final testDuration = DateTime.now().difference(_testStartTime);

    final entry = TestLogEntry(
      timestamp: DateTime.now(),
      testType: TestType.shortTerm,
      testId: _currentTestId,
      audioSource: 'live_microphone',
      sourceType: 'live',
      genre: _selectedGenre.name,
      subgenre: _selectedSubgenre.name,
      modelUsed: _key.modelUsed,
      fallbackModel: _key.fallbackModel,
      classicalEnabled: _key.currentConfig.useClassical,
      classicalWeight: _key.currentConfig.classicalWeight,
      detectedBpm: _displayBpm,
      bpmStability: _bpm.stability,
      bpmConfidence: _bpm.confidence,
      bpmLocked: _bpm.isLocked,
      detectedKey: _key.label,
      keyConfidence: _key.confidence,
      topThreeKeys: _key.topAlternates.map((a) => a.label).toList(),
      topThreeConfidences: _key.topAlternates.map((a) => a.score).toList(),
      tuningOffset: _key.tuningOffset,
      smoothingType: _key.currentConfig.smoothingType.name,
      smoothingStrength: _key.currentConfig.smoothingStrength,
      processingLatency:
      _frameCount > 0 ? testDuration.inMilliseconds / _frameCount : 0.0,
      droppedFrames: _droppedFrames,
      whiteningAlpha: _key.currentConfig.whiteningAlpha,
      bassSuppression: _key.currentConfig.bassSuppression,
      hpcpBins: _key.currentConfig.hpcpBins,
    );

    await _logger.logTestResult(entry);
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      await _stopRecording();
    } else {
      _dismissKeyboard();
      await _startRecording();
    }
  }

  void _resetAll() {
    _bpmHistory.clear();
    _taps.clear();
    _bpmCtrl.clear();
    _displayBpm = null;
    _liveBpm.value = null;
    _rms = 0.0;
    _peak = 0.0;
    _rmsDb = -120.0;
    _rmsHistory.clear();
    _key.reset();
    _bpm.reset();
    setState(() {});
  }

  // ===== ADAPTIVE SMOOTHING WINDOW (slightly more responsive) =====
  int _getAdaptiveSmoothWindow() {
    final currentBpm = _displayBpm ?? _bpm.bpm ?? 120.0;
    final isReasonable = currentBpm >= 95 && currentBpm <= 180;

    if (_bpm.isLocked && isReasonable && _bpm.stability > 0.85) {
      return _bpmSmoothWindowMax; // 15
    } else if (_bpm.isLocked && isReasonable && _bpm.stability > 0.75) {
      return 11;
    } else if (_bpm.isLocked && _bpm.stability > 0.65) {
      return 9;
    } else if (_bpm.stability > 0.50) {
      return 8;
    } else {
      return _bpmSmoothWindowMin; // 7
    }
  }

  void _processAudioBytes(Uint8List alignedBytes) {
    _bpm.addBytes(alignedBytes, channels: _channels, isFloat32: false);
    _key.addBytes(alignedBytes, channels: _channels, isFloat32: false);

    final int16 =
    alignedBytes.buffer.asInt16List(0, alignedBytes.lengthInBytes ~/ 2);

    double sumSq = 0.0;
    double maxAbs = 0.0;
    for (int i = 0; i < int16.length; i += _channels) {
      int sample = int16[i];
      if (_channels == 2 && i + 1 < int16.length) {
        sample = ((int16[i] + int16[i + 1]) / 2.0).round();
      }
      final x = sample / 32768.0;
      sumSq += x * x;
      final a = x.abs();
      if (a > maxAbs) maxAbs = a;
    }
    final n = math.max(1, int16.length ~/ _channels).asInt;
    final rms = math.sqrt(sumSq / n);
    final rmsDb = 20.0 * math.log(rms + 1e-12) / math.ln10;

    // Track RMS history (reserved for future beat energy validation)
    _rmsHistory.add(rms);
    if (_rmsHistory.length > _rmsHistorySize) _rmsHistory.removeAt(0);

    final estBpm = _bpm.bpm;

    setState(() {
      _rms = rms.clamp(0.0, 1.0).asDouble;
      _peak = maxAbs.clamp(0.0, 1.0).asDouble;
      _rmsDb = rmsDb;

      if (estBpm != null && estBpm > 0) {
        // SINGLE bounds check - clamp and continue
        if (estBpm < 50 || estBpm > 200) {
          return; // Skip clearly wrong values
        }

        _bpmHistory.add(estBpm);
        final windowSize = _getAdaptiveSmoothWindow();
        if (_bpmHistory.length > windowSize) _bpmHistory.removeAt(0);

        // Require minimum history before any updates
        if (_bpmHistory.length < windowSize) {
          return;
        }

        final sorted = List<double>.from(_bpmHistory)..sort();
        var smoothBpm = sorted[sorted.length ~/ 2];

        smoothBpm = _refineBpm(smoothBpm);

        // ===== CONDITIONAL WOBBLE PREVENTION v3.0 =====
        // CRITICAL FIX: Different behavior for suspicious vs reasonable tempos
        if (_bpm.isLocked && _displayBpm != null) {
          final diff = (smoothBpm - _displayBpm!).abs();
          final isReasonableTempo = _displayBpm! >= 95 && _displayBpm! <= 180;
          final isSuspiciousTempo = _displayBpm! >= 55 && _displayBpm! < 95; // Half-tempo zone!

          // CRITICAL: If locked on suspicious tempo, ALLOW big corrections
          if (isSuspiciousTempo && diff > 20.0) {
            // Big jump from half-tempo zone - this is likely a correction!
            // Use moderate smoothing to allow the fix through
            smoothBpm = _displayBpm! * 0.30 + smoothBpm * 0.70; // 70% new value
            debugPrint('🔓 ALLOWING CORRECTION from suspicious tempo: $_displayBpm → $smoothBpm');
          } else if (isSuspiciousTempo && diff > 10.0) {
            // Medium jump - still allow more through
            smoothBpm = _displayBpm! * 0.45 + smoothBpm * 0.55;
          } else if (isReasonableTempo) {
            // Normal case: reasonable tempo, apply stability-based smoothing
            if (_bpm.stability > 0.92 && diff < 8.0) {
              // Very high stability: strong smoothing (but not as extreme as before)
              smoothBpm = _displayBpm! * 0.92 + smoothBpm * 0.08; // Was 0.99/0.01
            } else if (_bpm.stability > 0.88 && diff < 10.0) {
              smoothBpm = _displayBpm! * 0.88 + smoothBpm * 0.12; // Was 0.98/0.02
            } else if (_bpm.stability > 0.82 && diff < 15.0) {
              smoothBpm = _displayBpm! * 0.85 + smoothBpm * 0.15; // Was 0.96/0.04
            } else if (_bpm.stability > 0.75 && diff < 20.0) {
              smoothBpm = _displayBpm! * 0.80 + smoothBpm * 0.20; // Was 0.93/0.07
            } else if (_bpm.stability > 0.65 && diff < 25.0) {
              smoothBpm = _displayBpm! * 0.75 + smoothBpm * 0.25; // Was 0.88/0.12
            }
          }
        }

        // ===== IMPROVED DISPLAY UPDATE CONTROL v3.0 =====
        // More responsive: reduced frame requirement
        _framesSinceLastUpdate++;
        final now = DateTime.now();
        final timeSinceUpdate = now.difference(_lastDisplayUpdate).inMilliseconds;

        final enoughFrames = _framesSinceLastUpdate >= 20; // Was 30
        final enoughTime = timeSinceUpdate >= 1500; // Was 2000 (1.5 seconds)

        final significantChange = _displayBpm == null ||
            (smoothBpm - _displayBpm!).abs() > 1.5; // Was 2.0

        final shouldUpdate = (enoughFrames && enoughTime) ||
            (_bpm.isLocked && significantChange && enoughTime);

        if (!shouldUpdate) {
          return;
        }

        // Update display
        _lastDisplayUpdate = now;
        _framesSinceLastUpdate = 0;
        _displayBpm = smoothBpm;

        debugPrint('✓ DISPLAY UPDATED: $smoothBpm BPM (stability: ${(_bpm.stability * 100).toStringAsFixed(0)}%, locked: ${_bpm.isLocked})');

        if (!_bpmFocus.hasFocus) {
          _bpmCtrl.text = smoothBpm.toStringAsFixed(1);
        }

        _liveBpm.value = _displayBpm;

        // Auto "Trap" nudge
        if (!_autoTrapApplied &&
            !_bpm.isLocked &&
            _selectedGenre == Genre.hiphop &&
            _selectedSubgenre == Subgenre.none &&
            (_key.confidence < 0.12) &&
            smoothBpm >= 60 &&
            smoothBpm <= 100) {
          _autoTrapApplied = true;
          _key.switchGenre(Genre.hiphop, subgenre: Subgenre.trap);
        }
      }
    });
  }

  double _fold(double x, double minB, double maxB) {
    while (x < minB && x * 2.0 <= maxB) x *= 2.0;
    while (x > maxB && x / 2.0 >= minB) x /= 2.0;
    return x;
  }

  // ===== SIMPLIFIED BPM RESOLVER v3.0 =====
  // Removed conflicting corrections, kept only the most effective
  double _refineBpm(double raw) {
    double v = raw * (1.0 + kGlobalBpmBiasPct / 100.0);

    final double minB = _settings.minBpm;
    final double maxB = _settings.maxBpm;

    v = _fold(v, minB, maxB);

    final hint = _hintBpm;
    final conf = _bpm.confidence;
    final stab = _bpm.stability;
    final prev = _displayBpm;
    final locked = _bpm.isLocked;

    // Pull ACF peaks for scoring
    final List<Map<String, dynamic>> tops =
        (_bpm.debugStats['last_acf_top'] as List?)
            ?.cast<Map<String, dynamic>>() ??
            const [];

    double acfStrengthFor(double targetBpm) {
      if (tops.isEmpty || targetBpm <= 0) return 0.0;
      double maxScore = 0.0;
      for (final peak in tops) {
        final peakBpm = (peak['bpm'] as num?)?.toDouble() ?? 0.0;
        final score = (peak['score'] as num?)?.toDouble() ?? 0.0;
        if (peakBpm <= 0) continue;

        final ratio = targetBpm / peakBpm;
        if ((ratio - 1.0).abs() < 0.035) {
          maxScore = math.max(maxScore, score);
        } else if ((ratio - 0.5).abs() < 0.035 || (ratio - 2.0).abs() < 0.035) {
          maxScore = math.max(maxScore, score * 0.50);
        }
      }
      return maxScore;
    }

    // ===== PRE-LOCK VALIDATION (prevent locking on wrong tempo) =====
    // CRITICAL: Before we get to scoring, validate if we're about to lock
    if (stab > 0.85 && !locked) {
      // About to lock - make SURE we're not at half-tempo
      if (v >= 55 && v <= 90) {
        final dbl = v * 2.0;
        if (dbl >= 100 && dbl <= 180) {
          final vAcf = acfStrengthFor(v);
          final dblAcf = acfStrengthFor(dbl);

          // VERY aggressive - we're about to lock!
          if (dblAcf > vAcf * 0.40) {
            v = dbl;
            debugPrint('🔧 PRE-LOCK CORRECTION: ${v/2} → $v BPM');
          }
        }
      }
    }

    // ===== CANDIDATE SCORING =====
    final baseRatios = <double>[
      0.5, 0.67, 0.75, 1.0, 1.33, 1.5, 2.0,
      0.6, 0.8, 1.25, 1.6, 1.8,
    ];

    final candidates = <double>{
      for (final r in baseRatios) _fold(v * r, minB, maxB),
    }.toList();

    if (hint != null && hint > 0) {
      for (final h in [hint, hint * 0.5, hint * 2.0, hint * 1.5, hint * 0.67]) {
        candidates.add(_fold(h, minB, maxB));
      }
    }

    double scoreCandidate(double bpm) {
      double s = 0.0;

      // (1) ACF support
      final acf = acfStrengthFor(bpm);
      s -= acf * 28.0;

      // (2) Stay near raw
      final dev = (bpm - v).abs() / (v + 1e-9);
      final devWeight = locked ? 4.0 : 2.0;
      s += dev * devWeight;

      // (3) Post-lock hysteresis
      if (locked && prev != null) {
        final rel = (bpm - prev).abs() / (prev + 1e-9);
        final hystWeight = 20.0 * stab; // Stronger than before

        if (rel > 0.04) {
          s += hystWeight * 2.5;
        } else if (rel > 0.02) {
          s += hystWeight * 1.0;
        }
      } else if (prev != null && stab >= 0.60) {
        s += (math.log((bpm / prev).abs() + 1e-9) / math.ln2).abs() * 0.8;
      }

      // (4) Hint attraction
      if (hint != null && hint > 0) {
        final fh = _fold(hint, minB, maxB);
        final rh = (bpm - fh).abs() / (fh + 1e-9);
        s += math.min(rh, 0.15);
      }

      // (5) Genre priors
      if (_selectedGenre == Genre.hiphop || _selectedGenre == Genre.auto) {
        if (bpm >= 65 && bpm <= 115) s -= 0.20;
        if (bpm > 145) s += 0.15;
      }
      if (_selectedGenre == Genre.electronic || _selectedGenre == Genre.auto) {
        if (bpm >= 115 && bpm <= 145) s -= 0.30;
        if (bpm < 90) s += 0.25;
      }
      if (_selectedGenre == Genre.rock || _selectedGenre == Genre.auto) {
        if (bpm >= 105 && bpm <= 125) s -= 0.20;
      }

      // (6) Musical tempo prior - STRONG preference
      if (bpm >= 105 && bpm <= 175) {
        s -= 0.70; // Strong bonus for reasonable range
      } else if (bpm >= 95 && bpm <= 185) {
        s -= 0.30;
      }

      // (7) Stability reward
      if (conf > 0.75 && stab > 0.7 && dev < 0.05) {
        s -= 3.0;
      } else if (conf > 0.6 && stab > 0.65 && dev < 0.08) {
        s -= 1.5;
      }

      // (8) CRITICAL: Penalize half-tempo zone when about to lock
      if (stab > 0.85 && bpm >= 55 && bpm <= 90) {
        s += 6.0; // HUGE penalty to prevent locking here
      }

      // Also penalize known problem zones
      if (bpm >= 60 && bpm <= 75) {
        if (_selectedGenre != Genre.hiphop && _selectedGenre != Genre.jazz) {
          s += 0.50;
        }
      }

      return s;
    }

    candidates.sort((a, b) => scoreCandidate(a).compareTo(scoreCandidate(b)));
    double best = candidates.first;

    // ===== ADAPTIVE SNAPPING =====
    if (locked && conf >= 0.85 && stab >= 0.80) {
      final rounded = (best * 2).round() / 2.0;
      if ((rounded - best).abs() <= 0.20) {
        best = rounded;
      }
    } else if (locked && conf >= 0.75 && stab >= 0.75) {
      final rounded = best.round().toDouble();
      if ((rounded - best).abs() <= 0.35) {
        best = rounded;
      }
    }

    // ===== FINAL SANITY CHECK (simplified) =====
    if (!locked || stab < 0.70) {
      // Half-tempo check
      if (best >= 55 && best <= 85) {
        final dbl = best * 2.0;
        if (dbl >= 110 && dbl <= 180) {
          final bestAcf = acfStrengthFor(best);
          final dblAcf = acfStrengthFor(dbl);

          if (dblAcf > bestAcf * 0.55) {
            best = dbl;
            debugPrint('🔧 FINAL CORRECTION: ${best/2} → $best BPM');
          }
        }
      }
    }

    return best;
  }

  void _handleTapTempo() {
    _dismissKeyboard();
    final now = DateTime.now();
    _taps.removeWhere((t) => now.difference(t).inMilliseconds > 3000);
    _taps.add(now);
    if (_taps.length >= 2) {
      double avgMs = 0.0;
      for (int i = 1; i < _taps.length; i++) {
        avgMs += _taps[i].difference(_taps[i - 1]).inMilliseconds.asDouble;
      }
      avgMs /= (_taps.length - 1);
      if (avgMs > 0) {
        final bpm = 60000.0 / avgMs;
        setState(() {
          _displayBpm = bpm;
          _bpmCtrl.text = bpm.toStringAsFixed(1);
          _liveBpm.value = _displayBpm;
        });
      }
    }
  }

  void _applyBpmFromField() {
    final v = double.tryParse(_bpmCtrl.text.trim());
    if (v != null && v > 0) {
      setState(() {
        _displayBpm = v;
        _liveBpm.value = _displayBpm;
      });
    }
  }

  void _dismissKeyboard() => FocusScope.of(context).unfocus();

  Future<void> _openSettings() async {
    final result = await Navigator.of(context).push<AppSettings>(
      MaterialPageRoute(builder: (_) => SettingsPage(initial: _settings)),
    );
    if (result != null && mounted) {
      setState(() {
        _settings = result;
        _buildAnalyzers(sampleRate: _sampleRate);
      });
    }
  }

  // ========== SHARE / IMPORT HELPERS ==========

  Future<File?> _findLatestCsvInDocs() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final entries = await dir.list(recursive: false).toList();
      final csvs = entries
          .whereType<File>()
          .where((f) => p.extension(f.path).toLowerCase() == '.csv')
          .toList();
      if (csvs.isEmpty) return null;
      csvs.sort((a, b) {
        final at = FileStat.statSync(a.path).modified;
        final bt = FileStat.statSync(b.path).modified;
        return bt.compareTo(at);
      });
      return csvs.first;
    } catch (_) {
      return null;
    }
  }

  Future<void> _shareLatestCsv() async {
    final f = await _findLatestCsvInDocs();
    if (f == null || !await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No CSV found in app documents yet')),
      );
      return;
    }
    await Share.shareXFiles(
      [XFile(f.path)],
      subject: 'HarmoniQ Export',
      text: 'Exported test logs: ${p.basename(f.path)}',
    );
  }

  Future<void> _importCsvToDocuments() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        withData: true,
      );
      if (result == null) return;

      final bytes = result.files.single.bytes;
      final fromPath = result.files.single.path;
      final name = result.files.single.name;
      if (bytes == null && fromPath == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read selected file')),
        );
        return;
      }

      final docs = await getApplicationDocumentsDirectory();
      final destPath = p.join(docs.path, name);
      final outFile = File(destPath);
      await outFile.writeAsBytes(bytes ?? await File(fromPath!).readAsBytes());

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Imported to Documents: ${p.basename(destPath)}'),
          action: SnackBarAction(
            label: 'Share',
            onPressed: () => Share.shareXFiles([XFile(destPath)]),
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }

  Future<void> _exportLogs() async {
    await _logger.exportResults(asJson: false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logs exported to app documents')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyLabel = _key.label;
    final keyConf = _key.confidence.clamp(0, 1.0).asDouble;
    final bpmStr =
        _displayBpm?.toStringAsFixed(1) ?? (_bpm.bpm?.toStringAsFixed(1) ?? '--');
    final isLocked = _bpm.isLocked;
    final tuningOffset = _key.tuningOffset;

    const lowKeyConfGate = 0.02;
    final showKeyNow = keyConf >= lowKeyConfGate;
    final displayedKey = showKeyNow ? keyLabel : '--';
    final keySubtitle = showKeyNow
        ? (tuningOffset != null
        ? '${tuningOffset > 0 ? '+' : ''}${tuningOffset.toStringAsFixed(1)}¢'
        : null)
        : 'analyzing...';

    return GestureDetector(
      onTap: _dismissKeyboard,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('HarmoniQ Analyzer v3.0'),
          actions: [
            IconButton(
              tooltip: 'Export Logs',
              icon: const Icon(Icons.download),
              onPressed: _exportLogs,
            ),
            IconButton(
              tooltip: 'Share Latest CSV',
              icon: const Icon(Icons.ios_share),
              onPressed: _shareLatestCsv,
            ),
            IconButton(
              tooltip: 'Import CSV to Documents',
              icon: const Icon(Icons.file_upload_outlined),
              onPressed: _importCsvToDocuments,
            ),
            IconButton(
              tooltip: 'Paid Tools',
              icon: const Icon(Icons.workspace_premium_outlined),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PaidToolsPage(liveBpm: _liveBpm),
                  ),
                );
              },
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'system') {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SystemAudioPage()),
                  );
                } else if (v == 'settings') {
                  _openSettings();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'system', child: Text('System Audio')),
                PopupMenuItem(value: 'settings', child: Text('Settings')),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_lastError != null)
                Card(
                  color: Colors.red.withValues(alpha: 0.15),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_lastError!)),
                      ],
                    ),
                  ),
                ),

              _SectionCard(
                title: 'Genre Configuration',
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<Genre>(
                            value: _selectedGenre,
                            decoration: const InputDecoration(
                              labelText: 'Genre',
                              border: OutlineInputBorder(),
                            ),
                            items: Genre.values
                                .map((g) => DropdownMenuItem(
                              value: g,
                              child: Text(g.name),
                            ))
                                .toList(),
                            onChanged: _onGenreChanged,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<Subgenre>(
                            value: _selectedSubgenre,
                            decoration: const InputDecoration(
                              labelText: 'Subgenre',
                              border: OutlineInputBorder(),
                            ),
                            items: _getSubgenresForGenre(_selectedGenre)
                                .map((s) => DropdownMenuItem(
                              value: s,
                              child: Text(s.name.replaceAll('_', ' ')),
                            ))
                                .toList(),
                            onChanged: _onSubgenreChanged,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Model: ${_key.modelUsed.split('/').last}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: _ResultCard(
                      title: 'Key',
                      value: displayedKey,
                      subtitle: keySubtitle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ResultCard(
                      title: 'Tempo',
                      value: '$bpmStr BPM',
                      isLocked: isLocked,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              _ConfidenceMeter(
                label: 'Key Confidence',
                confidence: keyConf,
              ),
              if (_key.topAlternates.isNotEmpty && showKeyNow) ...[
                const SizedBox(height: 4),
                Text(
                  'Alternates: ${_key.topAlternates.take(3).map((a) => '${a.label} (${(a.score * 100).toStringAsFixed(0)}%)').join(', ')}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 4),
              _ConfidenceMeter(
                label: 'BPM Confidence',
                confidence: _bpm.confidence,
                secondary:
                'Stability: ${(_bpm.stability * 100).toStringAsFixed(0)}%',
              ),
              const SizedBox(height: 12),

              Center(
                child: Column(
                  children: [
                    _PressHoldMicButton(
                      isRecording: _recording,
                      onPressStart: _startRecording,
                      onPressEnd: _stopRecording,
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _toggleRecording,
                          icon: Icon(_recording ? Icons.stop : Icons.play_arrow),
                          label: Text(_recording ? 'Stop' : 'Start'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _resetAll,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Reset'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              _SectionCard(
                title: 'Live Mic Levels',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _LevelRow(
                        label: 'RMS',
                        value: _rms,
                        trailing: '${(_rmsDb).toStringAsFixed(1)} dB'),
                    const SizedBox(height: 8),
                    _LevelRow(label: 'Peak', value: _peak),
                    const SizedBox(height: 8),
                    Text('Sample rate $_sampleRate Hz • Channels $_channels'),
                    if (_recording) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Frames: $_frameCount • Dropped: $_droppedFrames',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),

              _SectionCard(
                title: 'Calibrate (Optional)',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      title: const Text('Use Hint BPM'),
                      subtitle: const Text(
                          'Constrains search range around expected tempo'),
                      value: _useHint,
                      onChanged: (v) {
                        setState(() {
                          _useHint = v;
                          _buildAnalyzers(sampleRate: _sampleRate);
                          _bpm.reset();
                        });
                      },
                    ),
                    if (_useHint) ...[
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _hintCtrl,
                              keyboardType:
                              const TextInputType.numberWithOptions(
                                  decimal: true),
                              decoration: const InputDecoration(
                                labelText: 'Hint BPM',
                                border: OutlineInputBorder(),
                              ),
                              onSubmitted: (_) {
                                setState(() {
                                  _buildAnalyzers(sampleRate: _sampleRate);
                                  _bpm.reset();
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          ElevatedButton(
                            onPressed: () {
                              setState(() {
                                _buildAnalyzers(sampleRate: _sampleRate);
                                _bpm.reset();
                              });
                            },
                            child: const Text('Apply'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    SwitchListTile(
                      title: const Text('Tighten after lock'),
                      subtitle: const Text(
                          'Narrows range for steadier output once locked'),
                      value: _useTight,
                      onChanged: (v) {
                        setState(() {
                          _useTight = v;
                          _buildAnalyzers(sampleRate: _sampleRate);
                          _bpm.reset();
                        });
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              _SectionCard(
                title: 'Tempo Tools',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _bpmCtrl,
                            focusNode: _bpmFocus,
                            keyboardType:
                            const TextInputType.numberWithOptions(
                                decimal: true),
                            textInputAction: TextInputAction.done,
                            onEditingComplete: _applyBpmFromField,
                            onSubmitted: (_) => _applyBpmFromField(),
                            decoration: const InputDecoration(
                              labelText: 'Manual BPM',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          onPressed: _handleTapTempo,
                          child: const Text('Tap'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () {
                            setState(() {
                              _taps.clear();
                              _displayBpm = null;
                              _bpmCtrl.clear();
                              _liveBpm.value = null;
                            });
                          },
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: (_displayBpm ?? 0) > 0
                              ? () => setState(() {
                            _displayBpm = (_displayBpm! / 2)
                                .clamp(1.0, 500.0)
                                .asDouble;
                            _bpmCtrl.text =
                                _displayBpm!.toStringAsFixed(1);
                            _liveBpm.value = _displayBpm;
                          })
                              : null,
                          child: const Text('½x'),
                        ),
                        OutlinedButton(
                          onPressed: (_displayBpm ?? 0) > 0
                              ? () => setState(() {
                            _displayBpm = (_displayBpm! * 2)
                                .clamp(1.0, 500.0)
                                .asDouble;
                            _bpmCtrl.text =
                                _displayBpm!.toStringAsFixed(1);
                            _liveBpm.value = _displayBpm;
                          })
                              : null,
                          child: const Text('2x'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              _SectionCard(
                title: 'Music Math',
                child: _displayBpm != null && _displayBpm! > 0
                    ? _MusicMathThreeColumn(bpm: _displayBpm!)
                    : const Text('Enter or detect a BPM to see timing values'),
              ),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _exportLogs,
          icon: const Icon(Icons.save_alt),
          label: const Text('Export Logs'),
          tooltip: 'Export test logs (CSV in app docs)',
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      ),
    );
  }

  List<Subgenre> _getSubgenresForGenre(Genre genre) {
    switch (genre) {
      case Genre.electronic:
        return [
          Subgenre.none,
          Subgenre.house,
          Subgenre.techno,
          Subgenre.trance,
          Subgenre.dubstep,
          Subgenre.drumnbass,
          Subgenre.trap,
          Subgenre.future,
          Subgenre.ambient,
        ];
      case Genre.rock:
        return [
          Subgenre.none,
          Subgenre.classic,
          Subgenre.alternative,
          Subgenre.metal,
          Subgenre.punk,
          Subgenre.indie,
        ];
      case Genre.jazz:
        return [
          Subgenre.none,
          Subgenre.bebop,
          Subgenre.swing,
          Subgenre.fusion,
          Subgenre.smooth,
        ];
      case Genre.classical:
        return [
          Subgenre.none,
          Subgenre.baroque,
          Subgenre.romantic,
          Subgenre.modern,
        ];
      case Genre.hiphop:
        return [
          Subgenre.none,
          Subgenre.oldschool,
          Subgenre.newschool,
          Subgenre.lofi,
          Subgenre.trap,
        ];
      case Genre.rnb:
        return [
          Subgenre.none,
          Subgenre.contemporary,
          Subgenre.soul,
          Subgenre.funk,
        ];
      case Genre.pop:
        return [
          Subgenre.none,
          Subgenre.mainstream,
          Subgenre.synthpop,
          Subgenre.kpop,
        ];
      case Genre.country:
        return [
          Subgenre.none,
          Subgenre.traditional,
          Subgenre.modernCountry,
        ];
      case Genre.latin:
        return [
          Subgenre.none,
          Subgenre.salsa,
          Subgenre.reggaeton,
          Subgenre.bossa,
        ];
      case Genre.world:
        return [
          Subgenre.none,
          Subgenre.african,
          Subgenre.asian,
          Subgenre.middle_eastern,
        ];
      default:
        return [Subgenre.none];
    }
  }
}

// ============================================================================
// UI COMPONENTS
// ============================================================================

class _ResultCard extends StatelessWidget {
  final String title;
  final String value;
  final String? subtitle;
  final bool isLocked;

  const _ResultCard({
    required this.title,
    required this.value,
    this.subtitle,
    this.isLocked = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 3,
      child: Container(
        padding: const EdgeInsets.all(16),
        height: subtitle != null ? 110 : 100,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                if (isLocked) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.lock,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ],
            ),
            const Spacer(),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PressHoldMicButton extends StatelessWidget {
  final bool isRecording;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;

  const _PressHoldMicButton({
    required this.isRecording,
    required this.onPressStart,
    required this.onPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    final Color base =
    isRecording ? Colors.redAccent : Theme.of(context).colorScheme.primary;
    final String label = isRecording ? 'Listening…' : 'Hold to Analyze';

    return GestureDetector(
      onLongPressStart: (_) => onPressStart(),
      onLongPressEnd: (_) => onPressEnd(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 180,
        height: 180,
        decoration: BoxDecoration(
          color: base.withValues(alpha: 0.12),
          shape: BoxShape.circle,
          border: Border.all(color: base, width: 3),
          boxShadow: [
            if (isRecording)
              BoxShadow(
                color: base.withValues(alpha: 0.5),
                blurRadius: 18,
                spreadRadius: 2,
              ),
          ],
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(isRecording ? Icons.mic : Icons.mic_none, size: 56, color: base),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(color: base, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfidenceMeter extends StatelessWidget {
  final String label;
  final double confidence;
  final String? secondary;

  const _ConfidenceMeter({
    required this.label,
    required this.confidence,
    this.secondary,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (confidence.clamp(0, 1) * 100).toStringAsFixed(0);
    final Color bar = confidence >= 0.75
        ? Colors.greenAccent
        : confidence >= 0.5
        ? Colors.amberAccent
        : Colors.redAccent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(label),
          if (secondary != null) ...[
            const Text(' • '),
            Text(secondary!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const Spacer(),
          Text('$pct%', style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: confidence.clamp(0, 1),
            minHeight: 10,
            color: bar,
            backgroundColor: Colors.white12,
          ),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _LevelRow extends StatelessWidget {
  final String label;
  final double value;
  final String? trailing;

  const _LevelRow({required this.label, required this.value, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 56, child: Text(label)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 16,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 88,
          child: Text(trailing ?? '${(value * 100).toStringAsFixed(0)}%'),
        ),
      ],
    );
  }
}

class _MusicMathThreeColumn extends StatelessWidget {
  final double bpm;
  const _MusicMathThreeColumn({required this.bpm});

  @override
  Widget build(BuildContext context) {
    final rows = MusicMathRows.buildThreeColumn(bpm);

    Widget cell(String title, MMCell c) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          border: Border(
              left: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Text('${c.ms.toStringAsFixed(2)} ms',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            Text('(${c.hz.toStringAsFixed(4)} Hz)',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Note Value',
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                  child:
                  Text('Notes', style: Theme.of(context).textTheme.labelLarge)),
              Expanded(
                  child: Text('Triplets',
                      style: Theme.of(context).textTheme.labelLarge)),
              Expanded(
                  child:
                  Text('Dotted', style: Theme.of(context).textTheme.labelLarge)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        ...rows.map((r) {
          return Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                    color:
                    Theme.of(context).dividerColor.withValues(alpha: 0.6)),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding:
                    const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                    child: Text(r.label),
                  ),
                ),
                cell('Notes', r.notes),
                cell('Triplets', r.triplets),
                cell('Dotted', r.dotted),
              ],
            ),
          );
        }),
      ],
    );
  }
}