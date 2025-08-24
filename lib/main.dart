import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
        // OPTION A: set darkness on the ColorScheme only
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
  // Analyze state
  bool _isRecording = false;
  double _confidence = 0.0;
  String _keyResult = '--';
  String _tempoResult = '--';

  // Music Math state
  final _bpmCtrl = TextEditingController(text: '120');
  double _bpm = 120;
  final List<DateTime> _taps = [];
  Timer? _tapResetTimer;

  @override
  void dispose() {
    _bpmCtrl.dispose();
    _tapResetTimer?.cancel();
    super.dispose();
  }

  // Analyze handlers (stubbed)
  void _onPressStart() {
    setState(() => _isRecording = true);
  }

  void _onPressEnd() {
    setState(() {
      _isRecording = false;
      // demo outputs for now
      _keyResult = 'C# minor';
      _tempoResult = '128 BPM';
      _confidence = 0.78;
    });
  }

  // Tap tempo
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
      'Thirty‑second': msPerBeat / 8,
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

            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),
            // Frequency response placeholder (for later wiring)
            Text('Frequency Response (Preview)',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const SizedBox(height: 180, child: SpectrumPlaceholder()),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

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
        duration: const Duration(milliseconds: 150),
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
                  spreadRadius: 2),
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

class SpectrumPlaceholder extends StatelessWidget {
  const SpectrumPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SpectrumPainter(),
      willChange: false,
      child: const SizedBox.expand(),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF121212);
    canvas.drawRect(Offset.zero & size, bg);

    final axis = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;

    // axes
    canvas.drawLine(Offset(0, size.height - 24), Offset(size.width, size.height - 24), axis);
    canvas.drawLine(const Offset(40, 0), Offset(40, size.height), axis);

    // labels
    final labels = ['20', '50', '100', '200', '500', '1k', '2k', '5k', '10k', '20k'];
    for (int i = 0; i < labels.length; i++) {
      final x = 40 + i * (size.width - 60) / (labels.length - 1);
      final tp = TextPainter(
        text: const TextSpan(
          text: '',
          style: TextStyle(color: Colors.white54, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      );
      final label = labels[i];
      final tp2 = TextPainter(
        text: TextSpan(text: label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp2.paint(canvas, Offset(x - tp2.width / 2, size.height - 22));
    }

    // fake spectrum
    final line = Paint()
      ..color = Colors.blueAccent
      ..strokeWidth = 2;

    final path = Path();
    for (int i = 0; i <= size.width.toInt(); i++) {
      final t = i / size.width;
      final y = size.height - 40
          - 60 * (math.sin(t * math.pi * 3) * 0.5 + 0.5)
          - 30 * math.exp(-6 * (t - 0.35) * (t - 0.35));
      if (i == 0) {
        path.moveTo(i.toDouble(), y);
      } else {
        path.lineTo(i.toDouble(), y);
      }
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

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
