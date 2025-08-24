import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HarmoniQApp());
}

class HarmoniQApp extends StatelessWidget {
  const HarmoniQApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'harmoniQ',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7F5BFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'SF Pro',
      ),
      home: const SimpleHome(),
    );
  }
}

class SimpleHome extends StatefulWidget {
  const SimpleHome({super.key});
  @override
  State<SimpleHome> createState() => _SimpleHomeState();
}

class _SimpleHomeState extends State<SimpleHome> {
  // Analyze summary
  bool _isRecording = false;
  double _confidence = 0.0;
  String _keyResult = '--';
  String _tempoResult = '--';

  // Live pitch
  double _liveFreq = 0.0;
  double _smoothFreq = 0.0;
  String _liveNote = '--';

  // Music Math
  final _bpmCtrl = TextEditingController(text: '120');
  double _bpm = 120;
  final List<DateTime> _taps = [];
  Timer? _tapResetTimer;

  // Audio / spectrum
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioSub;

  static const int _fftSize = 2048;     // power of 2
  static const int _channels = 1;       // mono
  static const int _sampleRate = 44100; // 44.1 kHz

  final List<double> _rolling = List.filled(_fftSize, 0.0, growable: false);
  int _rollIndex = 0;

  List<double> _spectrum = List.filled(_fftSize ~/ 2, 0.0, growable: false);
  Timer? _throttleTimer;

  @override
  void dispose() {
    _bpmCtrl.dispose();
    _tapResetTimer?.cancel();
    _audioSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  // ===== Analyze handlers =====
  Future<void> _onPressStart() async {
    try {
      // hasPermission() on this plugin checks/request if needed
      if (!await _recorder.hasPermission()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
        return;
      }

      // Start a PCM16 stream
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: _channels,
        ),
      );

      await _audioSub?.cancel();
      _audioSub = stream.listen(_onAudioBytes, onError: (e, _) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Audio error: $e')));
      });

      setState(() {
        _isRecording = true;
        _liveFreq = 0;
        _smoothFreq = 0;
        _liveNote = '--';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Start error: $e')));
    }
  }

  Future<void> _onPressEnd() async {
    try {
      await _audioSub?.cancel();
      _audioSub = null;
      await _recorder.stop();

      setState(() {
        _isRecording = false;
        // demo summary for now
        _keyResult = 'C# minor';
        _tempoResult = '128 BPM';
        _confidence = 0.78;
      });
    } catch (_) {}
  }

  // Stream callback (PCM16 bytes)
  void _onAudioBytes(Uint8List bytes) {
    if (bytes.isEmpty) return;

    // Interpret as int16 samples
    final i16 = Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);

    // Roll into circular buffer, convert to [-1,1] doubles
    for (int i = 0; i < i16.length; i++) {
      _rolling[_rollIndex] = (i16[i] / 32768.0).clamp(-1.0, 1.0);
      _rollIndex = (_rollIndex + 1) % _rolling.length;
    }

    // throttle ~20 fps
    if (_throttleTimer != null && _throttleTimer!.isActive) return;
    _throttleTimer = Timer(const Duration(milliseconds: 50), () {});

    // build FFT window from rolling buffer
    final window = List<double>.filled(_fftSize, 0.0);
    int idx = _rollIndex;
    for (int i = 0; i < _fftSize; i++) {
      window[i] = _rolling[idx];
      idx = (idx + 1) % _rolling.length;
    }

    _applyHann(window);

    final real = List<double>.from(window);
    final imag = List<double>.filled(_fftSize, 0.0);
    _fftRadix2(real, imag);

    // magnitude spectrum
    final mags = List<double>.filled(_fftSize ~/ 2, 0.0);
    double maxMag = 1e-9;
    for (int k = 0; k < mags.length; k++) {
      final m = math.sqrt(real[k] * real[k] + imag[k] * imag[k]);
      mags[k] = m;
      if (m > maxMag) maxMag = m;
    }
    for (int k = 0; k < mags.length; k++) {
      final n = mags[k] / maxMag;
      mags[k] = math.sqrt(n.clamp(0.0, 1.0)); // light compression
    }

    // pick dominant frequency in musical band
    int bestK = 1;
    double bestV = 0;
    for (int k = 1; k < mags.length; k++) {
      final f = (k * _sampleRate) / _fftSize;
      if (f < 80 || f > 2000) continue;
      final v = mags[k];
      if (v > bestV) {
        bestV = v;
        bestK = k;
      }
    }
    final freq = (bestK * _sampleRate) / _fftSize;

    // smooth readout
    _smoothFreq = _smoothFreq == 0 ? freq : (_smoothFreq * 0.8 + freq * 0.2);
    final note = _freqToNoteName(_smoothFreq);

    if (!mounted) return;
    setState(() {
      _spectrum = mags;
      _liveFreq = _smoothFreq;
      _liveNote = note;
    });
  }

  // ===== Music Math =====
  void _onTapTempo() {
    final now = DateTime.now();
    _taps.add(now);

    _tapResetTimer?.cancel();
    _tapResetTimer = Timer(const Duration(seconds: 2), () {
      _taps.clear();
      if (mounted) setState(() {});
    });

    if (_taps.length >= 2) {
      double totalMs = 0;
      for (int i = 1; i < _taps.length; i++) {
        totalMs += _taps[i].difference(_taps[i - 1]).inMilliseconds.toDouble();
      }
      final avgMs = totalMs / (_taps.length - 1);
      if (avgMs > 0) {
        final bpm = 60000.0 / avgMs;
        if (bpm > 20 && bpm < 300) {
          _bpm = bpm;
          _bpmCtrl.text = _bpm.toStringAsFixed(1);
          setState(() {});
        }
      }
    } else {
      setState(() {});
    }
  }

  Map<String, double> get _durationsMs {
    final msPerBeat = 60000.0 / _bpm;
    return {
      '1 bar, 4 beats': msPerBeat * 4,
      'Whole note': msPerBeat * 4,
      'Half note': msPerBeat * 2,
      'Quarter note': msPerBeat,
      'Eighth note': msPerBeat / 2,
      'Sixteenth': msPerBeat / 4,
      'Thirty-second': msPerBeat / 8,
      'Dotted quarter': msPerBeat * 1.5,
      'Triplet quarter': msPerBeat * 2 / 3,
      'Dotted eighth': msPerBeat * 0.75,
      'Triplet eighth': msPerBeat / 3,
      'Dotted sixteenth': msPerBeat * 0.375,
      'Triplet sixteenth': msPerBeat / 6,
    };
  }

  String _fmt(double v) => v.toStringAsFixed(2);

  Future<void> _copyValue(String label, double ms) async {
    final text = '$label: ${_fmt(ms)} ms at ${_bpm.toStringAsFixed(1)} BPM';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied "$text"')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _durationsMs.entries.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('harmoniQ'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ANALYZE
            Text('Analyze', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            ConfidenceMeter(confidence: _confidence),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ResultCard(title: 'Key', value: _keyResult),
                _ResultCard(title: 'Tempo', value: _tempoResult),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: PressHoldMicButton(
                isRecording: _isRecording,
                onPressStart: _onPressStart,
                onPressEnd: _onPressEnd,
              ),
            ),
            const SizedBox(height: 12),

            // Live spectrum + pitch
            SizedBox(height: 180, child: SpectrumView(magnitudes: _spectrum)),
            const SizedBox(height: 8),
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.music_note),
                    const SizedBox(width: 8),
                    Text('Live Pitch', style: Theme.of(context).textTheme.labelLarge),
                    const Spacer(),
                    Text(
                      _liveNote == '--'
                          ? '--'
                          : '$_liveNote · ${_liveFreq.toStringAsFixed(1)} Hz',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),

            // MUSIC MATH
            Text('Music Math', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _bpmCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'BPM',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      final val = double.tryParse(v);
                      if (val != null && val > 0 && val < 500) {
                        setState(() => _bpm = val);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _onTapTempo,
                  child: const Text('Tap Tempo'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'BPM = ${_bpm.toStringAsFixed(1)}   |   1 beat = ${_fmt(60000.0 / _bpm)} ms',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),

            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: entries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final e = entries[i];
                return ListTile(
                  title: Text(e.key),
                  subtitle: Text('${_fmt(e.value)} ms'),
                  trailing: IconButton(
                    tooltip: 'Copy',
                    onPressed: () => _copyValue(e.key, e.value),
                    icon: const Icon(Icons.copy),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ===== UI widgets =====

class PressHoldMicButton extends StatelessWidget {
  final bool isRecording;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;

  const PressHoldMicButton({
    super.key,
    required this.isRecording,
    required this.onPressStart,
    required this.onPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    final Color base =
    isRecording ? Colors.redAccent : Theme.of(context).colorScheme.primary;
    final String label = isRecording ? 'Listening...' : 'Hold to Analyze';

    return GestureDetector(
      onLongPressStart: (_) => onPressStart(),
      onLongPressEnd: (_) => onPressEnd(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 180,
        height: 180,
        decoration: BoxDecoration(
          color: base.withOpacity(0.12),
          shape: BoxShape.circle,
          border: Border.all(color: base, width: 3),
          boxShadow: [
            if (isRecording)
              BoxShadow(
                color: base.withOpacity(0.5),
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
            Text(label),
          ],
        ),
      ),
    );
  }
}

class ConfidenceMeter extends StatelessWidget {
  final double confidence; // 0.0 to 1.0
  const ConfidenceMeter({super.key, required this.confidence});

  @override
  Widget build(BuildContext context) {
    final pct = (confidence.clamp(0, 1) * 100).toStringAsFixed(0);
    final Color bar = confidence >= 0.75
        ? Colors.greenAccent
        : confidence >= 0.5
        ? Colors.amberAccent
        : Colors.redAccent;

    return Column(
      children: [
        Row(
          children: [
            const Text('Confidence'),
            const SizedBox(width: 8),
            Text('$pct%'),
          ],
        ),
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

class SpectrumView extends StatelessWidget {
  final List<double> magnitudes; // 0..1 normalized
  const SpectrumView({super.key, required this.magnitudes});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SpectrumPainter(magnitudes),
      willChange: true,
      child: const SizedBox.expand(),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  final List<double> mags;
  _SpectrumPainter(this.mags);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF121212);
    canvas.drawRect(Offset.zero & size, bg);

    final axis = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;

    // axes
    canvas.drawLine(
        Offset(0, size.height - 24), Offset(size.width, size.height - 24), axis);
    canvas.drawLine(const Offset(40, 0), Offset(40, size.height), axis);

    // labels
    final labels = ['20', '50', '100', '200', '500', '1k', '2k', '5k', '10k', '20k'];
    for (int i = 0; i < labels.length; i++) {
      final x = 40 + i * (size.width - 60) / (labels.length - 1);
      final tp = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: const TextStyle(color: Colors.white54, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, size.height - 22));
    }

    // bars
    if (mags.isEmpty) return;
    final barPaint = Paint()
      ..color = Colors.blueAccent
      ..strokeWidth = 2;

    final binCount = mags.length;
    final startBin = 1;
    final endBin = binCount - 1;
    final plotWidth = size.width - 60;

    for (int k = startBin; k < endBin; k++) {
      final t = (k - startBin) / (endBin - startBin);
      final x = 40 + t * plotWidth;

      final v = mags[k].clamp(0.0, 1.0);
      final h = v * (size.height - 60);
      final y = size.height - 40 - h;

      canvas.drawLine(Offset(x, size.height - 40), Offset(x, y), barPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) =>
      oldDelegate.mags != mags;
}

// ===== DSP helpers =====

void _applyHann(List<double> x) {
  final n = x.length;
  for (int i = 0; i < n; i++) {
    final w = 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
    x[i] *= w;
  }
}

void _fftRadix2(List<double> real, List<double> imag) {
  final n = real.length;
  if (n == 0) return;
  if ((n & (n - 1)) != 0) {
    throw ArgumentError('FFT size must be power of 2');
  }

  int j = 0;
  for (int i = 1; i < n; i++) {
    int bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j &= ~bit;
    }
    j |= bit;
    if (i < j) {
      final tr = real[i]; real[i] = real[j]; real[j] = tr;
      final ti = imag[i]; imag[i] = imag[j]; imag[j] = ti;
    }
  }

  for (int len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wlr = math.cos(ang);
    final wli = math.sin(ang);
    for (int i = 0; i < n; i += len) {
      double ur = 1.0, ui = 0.0;
      for (int k = 0; k < len ~/ 2; k++) {
        final j2 = i + k;
        final j3 = j2 + len ~/ 2;

        final tr = ur * real[j3] - ui * imag[j3];
        final ti = ur * imag[j3] + ui * real[j3];

        real[j3] = real[j2] - tr;
        imag[j3] = imag[j2] - ti;
        real[j2] += tr;
        imag[j2] += ti;

        final tmp = ur * wlr - ui * wli;
        ui = ur * wli + ui * wlr;
        ur = tmp;
      }
    }
  }
}

// freq -> note name like "A4"
String _freqToNoteName(double freq) {
  if (freq <= 0 || !freq.isFinite) return '--';
  final midi = 69 + 12 * (math.log(freq / 440.0) / math.ln2);
  final m = midi.round();
  const names = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'];
  final name = names[(m % 12 + 12) % 12];
  final octave = (m / 12).floor() - 1;
  return '$name$octave';
}

// Small result card used above
class _ResultCard extends StatelessWidget {
  final String title;
  final String value;
  const _ResultCard({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Container(
        width: 160,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Text(value, style: Theme.of(context).textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }
}
