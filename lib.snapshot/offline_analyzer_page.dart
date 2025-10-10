import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'bpm_estimator.dart';
import 'key_detector.dart';
import 'music_math.dart';
import 'genre_config.dart';

class OfflineAnalyzerPage extends StatefulWidget {
  final String? initialPath;
  const OfflineAnalyzerPage({super.key, this.initialPath});
  @override
  State<OfflineAnalyzerPage> createState() => _OfflineAnalyzerPageState();
}

class _OfflineAnalyzerPageState extends State<OfflineAnalyzerPage> {
  String? _srcPath;
  String? _wavPath;
  bool _busy = false;
  String? _err;
  late BpmEstimator _bpm;
  late KeyDetector _key;
  double? _displayBpm;
  String _keyLabel = '--';
  double _keyConf = 0.0;
  double? _tuning;
  List<String> _alts = [];
  @override
  void initState() {
    super.initState();
    _bpm = BpmEstimator(sampleRate: 44100);
    _key = KeyDetector(
      sampleRate: 44100,
      fftSize: 4096,
      hop: 2048,
      minHz: 55.0,
      maxHz: 5000.0,
    );
    if (widget.initialPath != null) {
      _srcPath = widget.initialPath;
      _analyze();
    }
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() {
      _err = null;
    });
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'm4a', 'aac', 'aiff', 'aif', 'caf'],
      allowMultiple: false,
    );
    if (res == null || res.files.isEmpty) return;
    _srcPath = res.files.single.path;
    if (_srcPath == null) return;
    await _analyze();
  }

  Future<File> _decodeToWav(String src) async {
    final dir = await getTemporaryDirectory();
    final out = p.join(
      dir.path,
      'harmoniq_decode_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    final cmd = [
      '-y',
      '-i',
      src,
      '-ac',
      '1',
      '-ar',
      '44100',
      '-vn',
      '-f',
      'wav',
      out,
    ].join(' ');
    final ses = await FFmpegKit.execute(cmd);
    final rc = await ses.getReturnCode();
    if (rc == null || !rc.isValueSuccess()) {
      throw Exception('FFmpeg decode failed');
    }
    return File(out);
  }

  Future<void> _analyze() async {
    if (_srcPath == null) return;
    setState(() {
      _busy = true;
      _err = null;
      _displayBpm = null;
      _keyLabel = '--';
      _alts = [];
    });
    try {
      final wav = await _decodeToWav(_srcPath!);
      _wavPath = wav.path;
      final bytes = await wav.readAsBytes();
      if (bytes.length < 44) throw Exception('WAV too short');
      final raw = bytes.sublist(44);
      final pcm = raw.buffer.asUint8List();
      _bpm.reset();
      _key.reset();
      const chunk = 44100 * 2 * 1;
      for (int i = 0; i < pcm.length; i += chunk) {
        final end = (i + chunk < pcm.length) ? i + chunk : pcm.length;
        final slice = pcm.sublist(i, end);
        _bpm.addBytes(slice, channels: 1, isFloat32: false);
        _key.addBytes(slice, channels: 1, isFloat32: false);
      }
      final bpm = _bpm.bpm;
      final label = _key.label;
      final conf = _key.confidence.clamp(0, 1.0);
      final tuning = _key.tuningOffset;
      final alt = _key.topAlternates.take(3).map((a) => a.label).toList();
      setState(() {
        _displayBpm = bpm;
        _keyLabel = label;
        _keyConf = conf;
        _tuning = tuning;
        _alts = alt;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _err = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bpmStr =
        _displayBpm != null ? '${_displayBpm!.toStringAsFixed(1)} BPM' : '--';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline Analyzer'),
        actions: [
          IconButton(onPressed: _pickFile, icon: const Icon(Icons.folder_open)),
          if (_srcPath != null)
            IconButton(onPressed: _analyze, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Center(
        child: _busy
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              )
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    if (_err != null) ...[
                      Text(_err!, style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 12),
                    ],
                    if (_srcPath != null) ...[
                      Text(
                        'Source: ${p.basename(_srcPath!)}',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                    ],
                    Card(
                      child: ListTile(
                        title: const Text('Tempo'),
                        subtitle: Text(bpmStr),
                      ),
                    ),
                    Card(
                      child: ListTile(
                        title: const Text('Key'),
                        subtitle: Text(
                          _keyLabel == '--'
                              ? '--'
                              : '$_keyLabel  (${(_keyConf * 100).toStringAsFixed(0)}%)',
                        ),
                        trailing: _tuning != null
                            ? Text(
                                '${_tuning! > 0 ? '+' : ''}${_tuning!.toStringAsFixed(1)}¢',
                              )
                            : null,
                      ),
                    ),
                    if (_alts.isNotEmpty)
                      Text('Alternates: ${_alts.join(', ')}'),
                    const SizedBox(height: 12),
                    if (_displayBpm != null && _displayBpm! > 0)
                      _MusicMathBlock(bpm: _displayBpm!),
                  ],
                ),
              ),
      ),
    );
  }
}

class _MusicMathBlock extends StatelessWidget {
  final double bpm;
  const _MusicMathBlock({required this.bpm});
  @override
  Widget build(BuildContext context) {
    final rows = MusicMathRows.buildThreeColumn(bpm);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Music Math'),
        const SizedBox(height: 6),
        ...rows.map(
          (r) => Row(
            children: [
              Expanded(child: Text(r.label)),
              Expanded(child: Text('${r.notes.ms.toStringAsFixed(2)} ms')),
              Expanded(child: Text('${r.triplets.ms.toStringAsFixed(2)} ms')),
              Expanded(child: Text('${r.dotted.ms.toStringAsFixed(2)} ms')),
            ],
          ),
        ),
      ],
    );
  }
}
