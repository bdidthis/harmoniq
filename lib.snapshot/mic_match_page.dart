// lib/mic_match_page.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audio_session/audio_session.dart';
import 'package:record/record.dart';

/// Mic Match (MVP)
/// - Captures PCM16 mono audio
/// - Computes a simple LTAS (long-term average spectrum)
/// - Scores against a tiny mock mic database (replace with your real engine)
/// - Shows basic levels & status
class MicMatchPage extends StatefulWidget {
  const MicMatchPage({super.key});
  @override
  State<MicMatchPage> createState() => _MicMatchPageState();
}

class _MicMatchPageState extends State<MicMatchPage> {
  final AudioRecorder _rec = AudioRecorder();
  AudioSession? _audioSession;

  StreamSubscription<RecordState>? _stateSub;
  StreamSubscription<Uint8List>? _audioSub;

  // Config
  int _sampleRate = 44100;
  int _channels = 1;

  // Ring buffer for LTAS frames (in samples)
  static const int _fftSize = 2048; // power of 2
  static const int _hop = 1024; // 50% overlap
  final List<int> _fifo = <int>[];

  // Levels
  double _rms = 0.0; // 0..1
  double _peak = 0.0; // 0..1
  double _rmsDb = -120; // approx dBFS
  int _framesCount = 0; // processed frames (FFT)
  Duration _recordingDur = Duration.zero;
  Stopwatch? _sw;

  // UI state
  bool _recording = false;
  String? _lastError;

  // Results
  List<MicScore> _scores = const [];

  // Simple engine bundled here for convenience
  late final MicMatchEngine _engine = MicMatchEngine();

  @override
  void dispose() {
    _audioSub?.cancel();
    _stateSub?.cancel();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _initAudioSession() async {
    _audioSession = await AudioSession.instance;
    await _audioSession?.configure(
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
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
  }

  Future<void> _start() async {
    if (_recording) return;
    setState(() => _lastError = null);

    try {
      await _initAudioSession();

      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        setState(() => _lastError = 'Microphone permission is required.');
        return;
      }

      // Try preferred configs
      final configs = <RecordConfig>[
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 44100,
          numChannels: 1,
        ),
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 48000,
          numChannels: 1,
        ),
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 32000,
          numChannels: 1,
        ),
      ];

      Stream<Uint8List>? audioStream;
      bool started = false;

      for (final cfg in configs) {
        try {
          audioStream = await _rec.startStream(cfg);
          _channels = cfg.numChannels;
          _sampleRate = cfg.sampleRate;
          started = true;
          break;
        } catch (_) {
          // try next
        }
      }

      if (!started || audioStream == null) {
        setState(() => _lastError = 'Could not start microphone stream.');
        return;
      }

      _fifo.clear();
      _framesCount = 0;
      _scores = const [];
      _sw = Stopwatch()..start();
      _recordingDur = Duration.zero;

      _stateSub?.cancel();
      _stateSub = _rec.onStateChanged().listen((_) {});

      _audioSub?.cancel();
      _audioSub = audioStream.listen((bytes) {
        try {
          if (bytes.isEmpty) return;

          // Alignment: drop a trailing odd byte if present (PCM16)
          Uint8List b = ((bytes.length & 1) == 1)
              ? bytes.sublist(0, bytes.length - 1)
              : bytes;
          if (b.isEmpty) return;

          // Defensive: some platforms may give a non-zero offset slice
          if (b.offsetInBytes != 0) {
            b = Uint8List.fromList(b);
          }

          _processBytes(b);
        } catch (e) {
          setState(() => _lastError = 'Frame error: $e');
        }
      });

      setState(() => _recording = true);
    } catch (e) {
      setState(() => _lastError = 'Start error: $e');
    }
  }

  Future<void> _stop() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    try {
      await _rec.stop();
    } catch (_) {}
    _sw?.stop();
    _recordingDur = _sw?.elapsed ?? Duration.zero;

    // Build LTAS & score on stop
    try {
      final ltas = _engine.buildLtasFromFifo(
        fifo: _fifo,
        fftSize: _fftSize,
        hop: _hop,
        sampleRate: _sampleRate,
      );
      final scores = _engine.scoreLtas(ltas);
      setState(() => _scores = scores);
    } catch (e) {
      setState(() => _lastError = 'Analyze error: $e');
    }

    setState(() => _recording = false);
  }

  void _toggle() => _recording ? _stop() : _start();

  void _processBytes(Uint8List bytes) {
    // Update duration
    if (_sw != null && _sw!.isRunning) {
      _recordingDur = _sw!.elapsed;
    }

    // Levels
    final int16 = bytes.buffer.asInt16List(
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ 2,
    );
    double sumSq = 0.0;
    double maxAbs = 0.0;

    for (int i = 0; i < int16.length; i += _channels) {
      int s = int16[i];
      if (_channels == 2 && i + 1 < int16.length) {
        s = ((int16[i] + int16[i + 1]) / 2.0).round();
      }
      final x = s / 32768.0;
      sumSq += x * x;
      final a = x.abs();
      if (a > maxAbs) maxAbs = a;
    }

    final n = math.max(1, int16.length ~/ _channels);
    final rms = math.sqrt(sumSq / n);
    final rmsDb = 20.0 * math.log(rms + 1e-12) / math.ln10;

    // Append to FIFO as raw little-endian bytes
    _fifo.addAll(bytes);

    // Process as many hop-sized blocks as possible into LTAS buckets later (on stop)
    // We keep it lightweight here; LTAS is built once on stop.

    setState(() {
      _rms = rms.clamp(0.0, 1.0);
      _peak = maxAbs.clamp(0.0, 1.0);
      _rmsDb = rmsDb;
    });
  }

  @override
  Widget build(BuildContext context) {
    final durStr = _formatDur(_recordingDur);
    return Scaffold(
      appBar: AppBar(title: const Text('Mic Match (MVP)')),
      body: ListView(
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
          Row(
            children: [
              Expanded(
                child: _MeterCard(
                  title: 'RMS',
                  primary: '${_rmsDb.toStringAsFixed(1)} dBFS',
                  value: _rms,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MeterCard(
                  title: 'Peak',
                  primary: '${(_peak * 100).toStringAsFixed(0)}%',
                  value: _peak,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Sample rate: $_sampleRate Hz • Ch: $_channels • Recorded: $durStr',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _toggle,
                icon: Icon(_recording ? Icons.stop : Icons.mic),
                label: Text(_recording ? 'Stop' : 'Start'),
              ),
              OutlinedButton.icon(
                onPressed: !_recording
                    ? () {
                        setState(() {
                          _fifo.clear();
                          _scores = const [];
                          _framesCount = 0;
                          _rms = 0.0;
                          _peak = 0.0;
                          _rmsDb = -120;
                          _recordingDur = Duration.zero;
                        });
                      }
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('Reset'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Top Matches',
            child: _scores.isEmpty
                ? const Text(
                    'No results yet. Record some audio, then Stop to analyze.',
                  )
                : Column(
                    children: _scores
                        .map(
                          (s) => ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: .12),
                              child: Text((s.score * 100).toStringAsFixed(0)),
                            ),
                            title: Text(s.name),
                            subtitle: Text(
                              'Score: ${(s.score * 100).toStringAsFixed(1)}  •  Type: ${s.type}  •  Tilt: ${s.tiltSign}',
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }

  String _formatDur(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

/// Simple visual meter card
class _MeterCard extends StatelessWidget {
  final String title;
  final String primary;
  final double value;
  const _MeterCard({
    required this.title,
    required this.primary,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Text(primary, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: value.clamp(0, 1),
                minHeight: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});
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
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                         Minimal “Engine” (MVP demo)                         */
/* -------------------------------------------------------------------------- */

/// A tiny LTAS-based matcher. Replace with your full engine later.
class MicMatchEngine {
  // Mock “database”: name, type, coarse tilt signature (low/mid/high weight)
  final List<_MicProfile> _db = const [
    _MicProfile('Shure SM7B', 'dynamic', [1.2, 1.0, 0.8]), // darker
    _MicProfile('Electro-Voice RE20', 'dynamic', [1.1, 1.0, 0.9]),
    _MicProfile('Neumann U87ai', 'condenser', [0.95, 1.0, 1.2]), // brighter
    _MicProfile('AKG C414 XLS', 'condenser', [1.0, 1.0, 1.15]),
    _MicProfile('Sony C800G', 'condenser', [0.9, 1.0, 1.3]),
  ];

  /// Build a very simple LTAS (3 coarse bands: lows/mids/highs)
  /// from the FIFO PCM16 bytes on STOP (so UI stays light).
  List<double> buildLtasFromFifo({
    required List<int> fifo,
    required int fftSize,
    required int hop,
    required int sampleRate,
  }) {
    if (fifo.isEmpty) return [0.0, 0.0, 0.0];

    // Convert entire fifo to Int16 samples (mono)
    final bytes = Uint8List.fromList(fifo);
    final int16 = bytes.buffer.asInt16List(
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ 2,
    );
    if (int16.isEmpty) return [0.0, 0.0, 0.0];

    // Make float32 mono series
    final Float32List mono = Float32List(int16.length);
    for (int i = 0; i < int16.length; i++) {
      mono[i] = int16[i] / 32768.0;
    }

    // DC removal + pre-emphasis
    final Float32List x = _preEmphasize(_dcRemove(mono));

    // Prepare window
    final Float32List hann = _hannWindow(fftSize);

    // Accumulate power by bands
    double low = 0.0, mid = 0.0, high = 0.0;
    int frames = 0;

    for (int start = 0; start + fftSize <= x.length; start += hop) {
      frames++;
      // Copy frame
      final Float32List re = Float32List(fftSize);
      final Float32List im = Float32List(fftSize);
      for (int n = 0; n < fftSize; n++) {
        re[n] = x[start + n] * hann[n];
      }
      // FFT
      _fftRadix2(re, im);
      // Magnitude^2
      final int half = fftSize ~/ 2;
      for (int k = 1; k < half; k++) {
        final double mag2 = re[k] * re[k] + im[k] * im[k];
        final double f = (k * sampleRate) / fftSize;
        if (f < 200.0) {
          low += mag2;
        } else if (f < 2000.0) {
          mid += mag2;
        } else {
          high += mag2;
        }
      }
    }

    if (frames == 0) return [0.0, 0.0, 0.0];
    low /= frames.toDouble();
    mid /= frames.toDouble();
    high /= frames.toDouble();

    // Normalize
    final sum = low + mid + high;
    if (sum <= 0) return [0.0, 0.0, 0.0];
    return [low / sum, mid / sum, high / sum];
  }

  List<MicScore> scoreLtas(List<double> ltas3) {
    if (ltas3.length != 3) return const [];
    final List<MicScore> out = [];
    for (final m in _db) {
      final double dL = (ltas3[0] - m.tilt[0]);
      final double dM = (ltas3[1] - m.tilt[1]);
      final double dH = (ltas3[2] - m.tilt[2]);
      // Simple inverse-distance score
      final double dist = math.sqrt(dL * dL + dM * dM + dH * dH);
      final double score = (1.0 / (1.0 + dist)).clamp(0.0, 1.0);
      out.add(
        MicScore(
          name: m.name,
          type: m.type,
          score: score,
          tiltSign: _tiltLabel(ltas3),
        ),
      );
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    return out.take(5).toList();
  }

  String _tiltLabel(List<double> t) {
    // Very coarse descriptor
    if (t[2] > t[0] + 0.1) return 'bright';
    if (t[0] > t[2] + 0.1) return 'dark';
    return 'neutral';
  }

  // --- DSP helpers ----

  Float32List _dcRemove(Float32List x) {
    double mean = 0.0;
    for (final v in x) {
      mean += v;
    }
    mean /= x.length;
    final out = Float32List(x.length);
    for (int i = 0; i < x.length; i++) {
      out[i] = x[i] - mean;
    }
    return out;
  }

  Float32List _preEmphasize(Float32List x, {double a = 0.97}) {
    final out = Float32List(x.length);
    out[0] = x[0];
    for (int i = 1; i < x.length; i++) {
      out[i] = x[i] - a * x[i - 1];
    }
    return out;
  }

  Float32List _hannWindow(int n) {
    final w = Float32List(n);
    for (int i = 0; i < n; i++) {
      w[i] = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / (n - 1)));
    }
    return w;
  }

  // In-place Radix-2 Cooley–Tukey FFT
  void _fftRadix2(Float32List re, Float32List im) {
    final int n = re.length;
    // bit-reverse
    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j &= ~bit;
      }
      j |= bit;
      if (i < j) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    // butterflies
    for (int len = 2; len <= n; len <<= 1) {
      final ang = -2.0 * math.pi / len;
      final wlenRe = math.cos(ang);
      final wlenIm = math.sin(ang);
      for (int i = 0; i < n; i += len) {
        double wRe = 1.0, wIm = 0.0;
        for (int k = 0; k < len ~/ 2; k++) {
          final int u = i + k;
          final int v = i + k + len ~/ 2;
          final double tRe = re[v] * wRe - im[v] * wIm;
          final double tIm = re[v] * wIm + im[v] * wRe;
          re[v] = re[u] - tRe;
          im[v] = im[u] - tIm;
          re[u] += tRe;
          im[u] += tIm;
          final double nwRe = wRe * wlenRe - wIm * wlenIm;
          final double nwIm = wRe * wlenIm + wIm * wlenRe;
          wRe = nwRe;
          wIm = nwIm;
        }
      }
    }
  }
}

class _MicProfile {
  final String name;
  final String type; // 'dynamic' or 'condenser', etc.
  final List<double> tilt; // [low, mid, high] nominal weights
  const _MicProfile(this.name, this.type, this.tilt);
}

class MicScore {
  final String name;
  final String type;
  final double score; // 0..1 (higher = better match)
  final String tiltSign; // 'bright' / 'dark' / 'neutral'
  const MicScore({
    required this.name,
    required this.type,
    required this.score,
    required this.tiltSign,
  });
}
