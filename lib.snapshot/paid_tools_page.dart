// lib/paid_tools_page.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'; // ValueListenable
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'offline_file_analyzer_page.dart';
import 'music_math.dart';

// Collision-proof extension for Paid Tools
extension NumConvert on num {
  double get asDouble => toDouble();
  int get asInt => toInt();
}

class PaidToolsPage extends StatefulWidget {
  final ValueListenable<double?>? liveBpm;
  const PaidToolsPage({super.key, this.liveBpm});

  @override
  State<PaidToolsPage> createState() => _PaidToolsPageState();
}

class _PaidToolsPageState extends State<PaidToolsPage> {
  // BPM & Tap
  final TextEditingController _bpmCtrl = TextEditingController();
  double? _displayBpm;
  final List<DateTime> _taps = [];

  // Metronome (no extra plugin)
  Timer? _metroTimer;
  bool _metroOn = false;
  int _beatIndex = 0;
  int _beatsPerBar = 4;

  // Note frequency chart
  bool _showNoteChart = false;

  @override
  void initState() {
    super.initState();
    widget.liveBpm?.addListener(_onLiveBpmChanged);
  }

  @override
  void dispose() {
    widget.liveBpm?.removeListener(_onLiveBpmChanged);
    _stopMetronome();
    _metroTimer?.cancel();
    _bpmCtrl.dispose();
    super.dispose();
  }

  void _onLiveBpmChanged() {
    final liveBpm = widget.liveBpm?.value;
    if (liveBpm != null && mounted) {
      setState(() {
        _displayBpm = liveBpm;
        _bpmCtrl.text = liveBpm.toStringAsFixed(1);
      });
    }
  }

  void _handleTapTempo() {
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
          if (_metroOn) _restartMetronome();
        });
      }
    }
  }

  void _applyBpmFromField() {
    final v = double.tryParse(_bpmCtrl.text.trim());
    if (v != null && v > 0) {
      setState(() {
        _displayBpm = v;
        if (_metroOn) _restartMetronome();
      });
    }
  }

  Duration get _beatDuration {
    final bpm = (_displayBpm ?? 120.0);
    final ms = 60000.0 / bpm;
    return Duration(milliseconds: ms.round());
  }

  void _startMetronome() {
    if (_metroOn) return;
    _metroOn = true;
    _beatIndex = 0;
    _metroTimer = Timer.periodic(_beatDuration, (_) => _tick());
    setState(() {});
  }

  void _restartMetronome() {
    _metroTimer?.cancel();
    _beatIndex = 0;
    _metroTimer = Timer.periodic(_beatDuration, (_) => _tick());
  }

  void _stopMetronome() {
    _metroTimer?.cancel();
    _metroTimer = null;
    _metroOn = false;
    setState(() {});
  }

  Future<void> _tick() async {
    final isDownbeat = (_beatIndex % _beatsPerBar) == 0;
    _beatIndex = (_beatIndex + 1) % _beatsPerBar;

    await SystemSound.play(SystemSoundType.click);
    if (isDownbeat) {
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.selectionClick();
    }

    if (mounted) setState(() {});
  }

  Future<void> _copyDelayTable() async {
    final bpm = _displayBpm;
    if (bpm == null) return;

    final rows = delayTableForBpm(bpm);
    final sb = StringBuffer('${bpm.toStringAsFixed(1)} BPM Delay Times\n');
    sb.writeln('-------------------');
    for (final r in rows) {
      sb.writeln('${r.label}: ${r.ms.toStringAsFixed(2)} ms');
    }

    await Clipboard.setData(ClipboardData(text: sb.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied delay table for ${bpm.toStringAsFixed(1)} BPM'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bpm = _displayBpm;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Paid Tools'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: bpm != null ? _copyDelayTable : null,
            tooltip: 'Copy Delay Table',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // NEW: Offline analyzer entry
            _SectionCard(
              title: 'Pro: Full-Track Analysis',
              child: ListTile(
                leading: const Icon(Icons.library_music_outlined),
                title: const Text('Offline Track Analyzer'),
                subtitle: const Text('Analyze full songs (BPM & Key)'),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const OfflineFileAnalyzerPage(),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),

            // Tempo section
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
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _applyBpmFromField(),
                          decoration: const InputDecoration(
                            labelText: 'Enter BPM',
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
                        onPressed: (bpm ?? 0) > 0
                            ? () => setState(() {
                                  _displayBpm =
                                      (bpm! / 2).clamp(1.0, 500.0).asDouble;
                                  _bpmCtrl.text =
                                      _displayBpm!.toStringAsFixed(1);
                                  if (_metroOn) _restartMetronome();
                                })
                            : null,
                        child: const Text('½x'),
                      ),
                      OutlinedButton(
                        onPressed: (bpm ?? 0) > 0
                            ? () => setState(() {
                                  _displayBpm =
                                      (bpm! * 2).clamp(1.0, 500.0).asDouble;
                                  _bpmCtrl.text =
                                      _displayBpm!.toStringAsFixed(1);
                                  if (_metroOn) _restartMetronome();
                                })
                            : null,
                        child: const Text('2x'),
                      ),
                    ],
                  ),
                  if (bpm != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Current BPM: ${bpm.toStringAsFixed(1)}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Metronome section
            _SectionCard(
              title: 'Metronome',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _metroOn ? _stopMetronome : _startMetronome,
                        icon: Icon(_metroOn ? Icons.stop : Icons.play_arrow),
                        label: Text(_metroOn ? 'Stop' : 'Start'),
                      ),
                      const SizedBox(width: 12),
                      const Text('Beats/Bar'),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: _beatsPerBar,
                        items: const [2, 3, 4, 5, 6, 7, 8]
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text('$v/4'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _beatsPerBar = v;
                            if (_metroOn) _restartMetronome();
                          });
                        },
                      ),
                    ],
                  ),
                  if (_metroOn) ...[
                    const SizedBox(height: 8),
                    Text('Playing at ${(bpm ?? 120.0).toStringAsFixed(1)} BPM'),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Music Math table
            if (bpm != null)
              _SectionCard(
                title: 'Music Math',
                child: _MusicMathThreeColumn(bpm: bpm),
              ),
            const SizedBox(height: 16),

            // Note Frequency Chart
            _SectionCard(
              title: 'Note Frequency Chart',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show frequency chart'),
                    value: _showNoteChart,
                    onChanged: (v) => setState(() => _showNoteChart = v),
                  ),
                  if (_showNoteChart) ...[
                    const SizedBox(height: 8),
                    _NoteFrequencyChart(),
                  ],
                ],
              ),
            ),

            // Scale Explorer
            const SizedBox(height: 16),
            _SectionCard(title: 'Scale Explorer', child: _ScaleExplorer()),
          ],
        ),
      ),
    );
  }
}

// ---------- UI Components ----------

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
                left: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 4),
                Text(
                  '${c.ms.toStringAsFixed(2)} ms',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  '(${c.hz.toStringAsFixed(4)} Hz)',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Note Value',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: Text(
                  'Notes',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Expanded(
                child: Text(
                  'Triplets',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Expanded(
                child: Text(
                  'Dotted',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        ...rows.map((r) {
          return Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 8,
                    ),
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

class _NoteFrequencyChart extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final notes = [
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

    List<Widget> octaves = [];
    for (int octave = 0; octave <= 8; octave++) {
      List<Widget> noteRows = [];
      for (int i = 0; i < notes.length; i++) {
        final note = notes[i];
        final midi = (octave + 1) * 12 + i;
        final freq = 440.0 * math.pow(2.0, (midi - 69) / 12);
        noteRows.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(width: 60, child: Text('$note$octave')),
                Text('${freq.toStringAsFixed(2)} Hz'),
              ],
            ),
          ),
        );
      }
      octaves.add(
        ExpansionTile(title: Text('Octave $octave'), children: noteRows),
      );
    }

    return Column(children: octaves);
  }
}

class _ScaleExplorer extends StatefulWidget {
  @override
  State<_ScaleExplorer> createState() => _ScaleExplorerState();
}

class _ScaleExplorerState extends State<_ScaleExplorer> {
  String _selectedKey = 'C major';

  @override
  Widget build(BuildContext context) {
    final keys = <String>[];
    final notes = [
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
    for (final note in notes) {
      keys.add('$note major');
      keys.add('$note minor');
    }

    List<String> scaleNotes = [];
    if (_selectedKey.contains('major')) {
      final root = _selectedKey.split(' ').first;
      scaleNotes = ScaleNotes.major(root);
    } else if (_selectedKey.contains('minor')) {
      final root = _selectedKey.split(' ').first;
      scaleNotes = ScaleNotes.naturalMinor(root);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButton<String>(
          isExpanded: true,
          value: _selectedKey,
          items: keys
              .map((k) => DropdownMenuItem(value: k, child: Text(k)))
              .toList(),
          onChanged: (v) => setState(() => _selectedKey = v ?? _selectedKey),
        ),
        const SizedBox(height: 12),
        Text(_selectedKey, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: scaleNotes.map((n) => Chip(label: Text(n))).toList(),
        ),
      ],
    );
  }
}
