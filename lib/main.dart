import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';

void main() => runApp(const HarmoniQApp());

class HarmoniQApp extends StatelessWidget {
  const HarmoniQApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'harmoniQ',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6C2CF1)),
        useMaterial3: true,
      ),
      home: const HomeTabs(),
    );
  }
}

class HomeTabs extends StatelessWidget {
  const HomeTabs({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('harmoniQ'),
          centerTitle: true,
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Analyze'),
              Tab(text: 'Paid'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            AnalyzeScreen(),
            PaidScreen(),
          ],
        ),
      ),
    );
  }
}

class AnalyzeScreen extends StatefulWidget {
  const AnalyzeScreen({super.key});
  @override
  State<AnalyzeScreen> createState() => _AnalyzeScreenState();
}

class _AnalyzeScreenState extends State<AnalyzeScreen> {
  bool _pressing = false;
  String _status = 'Ready';
  String _keyResult = '-';
  String _tempoResult = '-';
  String _tuningOffset = '-';
  double _confidenceLive = 0.0;
  String _confidenceText = '-';
  double _bpm = 120;

  Timer? _ticker;
  DateTime? _pressStart;
  List<double> _spectrum = List<double>.filled(64, 0);

  void _startHold() {
    if (_pressing) return;
    _pressing = true;
    _pressStart = DateTime.now();
    _confidenceLive = 0;
    _status = 'Listening... hold to analyze';
    _keyResult = '-';
    _tempoResult = '-';
    _tuningOffset = '-';
    _confidenceText = '-';
    _ticker?.cancel();
    final rand = Random();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (t) {
      final sec = DateTime.now().difference(_pressStart!).inMilliseconds / 1000.0;
      final target = (0.25 + sec / 3.0).clamp(0.0, 0.98);
      setState(() {
        _confidenceLive = target;
        _spectrum = List.generate(_spectrum.length, (i) {
          final base = 0.2 + 0.8 * sin((t.tick * 0.22) + i * 0.18).abs();
          return (base + rand.nextDouble() * 0.25).clamp(0, 1);
        });
      });
    });
    setState(() {});
  }

  void _stopHold() {
    if (!_pressing) return;
    _pressing = false;
    final sec = DateTime.now().difference(_pressStart!).inMilliseconds / 1000.0;
    _ticker?.cancel();
    final conf = (0.35 + sec / 4.0).clamp(0.35, 0.99);
    setState(() {
      _status = 'Analysis complete';
      _keyResult = 'C Major';
      _tempoResult = '120 BPM';
      _tuningOffset = '+5 cents';
      _confidenceLive = conf;
      _confidenceText = conf.toStringAsFixed(2);
    });
  }

  int _msFromBeats(double beats) {
    final msPerBeat = 60000 / _bpm;
    return (beats * msPerBeat).round();
  }

  Color _confidenceColor(BuildContext ctx) {
    if (_confidenceLive >= 0.8) return Colors.green;
    if (_confidenceLive >= 0.6) return Colors.orange;
    return Colors.red;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <_NoteRow>[
      _NoteRow('Whole', 4.0),
      _NoteRow('Half', 2.0),
      _NoteRow('Quarter', 1.0),
      _NoteRow('Eighth', 0.5),
      _NoteRow('Sixteenth', 0.25),
      _NoteRow('Dotted Half', 3.0),
      _NoteRow('Dotted Quarter', 1.5),
      _NoteRow('Dotted Eighth', 0.75),
      _NoteRow('Quarter Triplet', 2.0 / 3.0),
      _NoteRow('Eighth Triplet', 1.0 / 3.0),
    ];

    final buttonColor = _pressing
        ? theme.colorScheme.primary
        : theme.colorScheme.secondaryContainer;

    final buttonTextColor =
    _pressing ? theme.colorScheme.onPrimary : theme.colorScheme.onSecondaryContainer;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            children: [
              Card(
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text('Press and hold to analyze', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTapDown: (_) => _startHold(),
                        onTapUp: (_) => _stopHold(),
                        onTapCancel: () => _stopHold(),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                          decoration: BoxDecoration(
                            color: buttonColor,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            _pressing ? 'Release to stop' : 'Hold to Analyze',
                            style: theme.textTheme.titleMedium?.copyWith(color: buttonTextColor),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _SpectrumBar(values: _spectrum, active: _pressing),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _pressing ? null : _confidenceLive,
                        minHeight: 6,
                        color: _confidenceColor(context),
                        backgroundColor: theme.colorScheme.surfaceVariant,
                      ),
                      const SizedBox(height: 8),
                      Text(_status, textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, c) {
                  final wide = c.maxWidth > 700;
                  final results = Card(
                    elevation: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Results', style: theme.textTheme.titleLarge),
                          const SizedBox(height: 12),
                          _ResultRow(label: 'Key', value: _keyResult),
                          _ResultRow(label: 'Tempo', value: _tempoResult),
                          _ResultRow(label: 'Tuning Offset', value: _tuningOffset),
                          Row(
                            children: [
                              const Expanded(child: Text('Confidence')),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: _confidenceColor(context).withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: _confidenceColor(context)),
                                ),
                                child: Text(
                                  _confidenceText == '-' ? _confidenceLive.toStringAsFixed(2) : _confidenceText,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: _confidenceColor(context),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );

                  final musicMath = Card(
                    elevation: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Music Math', style: theme.textTheme.titleLarge),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  initialValue: _bpm.toStringAsFixed(0),
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'BPM',
                                    border: OutlineInputBorder(),
                                  ),
                                  onChanged: (v) {
                                    final parsed = double.tryParse(v);
                                    if (parsed != null && parsed > 0 && parsed < 400) {
                                      setState(() => _bpm = parsed);
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 2,
                                child: Slider(
                                  value: _bpm.clamp(20, 240),
                                  min: 20,
                                  max: 240,
                                  divisions: 220,
                                  label: '${_bpm.round()}',
                                  onChanged: (v) => setState(() => _bpm = v),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: theme.colorScheme.outlineVariant),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Table(
                              columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(1)},
                              border: TableBorder(
                                horizontalInside: BorderSide(color: theme.colorScheme.outlineVariant),
                              ),
                              children: [
                                const TableRow(
                                  children: [
                                    Padding(padding: EdgeInsets.all(8), child: Text('Note')),
                                    Padding(padding: EdgeInsets.all(8), child: Text('Milliseconds', textAlign: TextAlign.right)),
                                  ],
                                ),
                                ...[
                                  _NoteRow('Whole', 4.0),
                                  _NoteRow('Half', 2.0),
                                  _NoteRow('Quarter', 1.0),
                                  _NoteRow('Eighth', 0.5),
                                  _NoteRow('Sixteenth', 0.25),
                                  _NoteRow('Dotted Half', 3.0),
                                  _NoteRow('Dotted Quarter', 1.5),
                                  _NoteRow('Dotted Eighth', 0.75),
                                  _NoteRow('Quarter Triplet', 2.0 / 3.0),
                                  _NoteRow('Eighth Triplet', 1.0 / 3.0),
                                ].map((r) {
                                  final ms = _msFromBeats(r.beats);
                                  return TableRow(
                                    children: [
                                      Padding(padding: const EdgeInsets.all(8), child: Text(r.label)),
                                      Padding(padding: const EdgeInsets.all(8), child: Text('$ms', textAlign: TextAlign.right)),
                                    ],
                                  );
                                }),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );

                  return wide
                      ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: results),
                      const SizedBox(width: 16),
                      Expanded(child: musicMath),
                    ],
                  )
                      : Column(
                    children: [
                      results,
                      const SizedBox(height: 16),
                      musicMath,
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PaidScreen extends StatelessWidget {
  const PaidScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Card(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text('Frequency Response', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  const Text(
                    'This panel is part of the paid plan. Here you will see a live 20 Hz to 20 kHz curve with harmonics and resonance markers.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  const _FrequencyPlaceholder(values: []),
                  const SizedBox(height: 8),
                  Text(
                    'Upgrade to unlock the full spectrum analyzer.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final String label;
  final String value;
  const _ResultRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Expanded(child: Text('')),
          Expanded(child: Text(label)),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _SpectrumBar extends StatelessWidget {
  final List<double> values;
  final bool active;
  const _SpectrumBar({required this.values, required this.active});

  @override
  Widget build(BuildContext context) {
    final v = values.isEmpty ? List<double>.filled(64, 0) : values;
    return SizedBox(
      height: 36,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(v.length, (i) {
          final h = (v[i] * 32) + 4;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                height: h,
                decoration: BoxDecoration(
                  color: active ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.primary.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _FrequencyPlaceholder extends StatelessWidget {
  final List<double> values;
  const _FrequencyPlaceholder({required this.values});

  @override
  Widget build(BuildContext context) {
    final v = values.isEmpty ? List<double>.generate(64, (i) => sin(i * 0.12).abs()) : values;
    return SizedBox(
      height: 140,
      child: CustomPaint(painter: _FreqPainter(v)),
    );
  }
}

class _FreqPainter extends CustomPainter {
  final List<double> values;
  _FreqPainter(this.values);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..color = const Color(0xFF6C2CF1);
    final path = Path();
    final n = values.length;
    for (int i = 0; i < n; i++) {
      final x = size.width * (i / (n - 1));
      final y = size.height * (1 - values[i] * 0.9);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _FreqPainter oldDelegate) => oldDelegate.values != values;
}

class _NoteRow {
  final String label;
  final double beats;
  _NoteRow(this.label, this.beats);
}
