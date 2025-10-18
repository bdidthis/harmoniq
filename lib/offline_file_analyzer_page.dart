// lib/offline_file_analyzer_page.dart
// Full-song Offline Track Analyzer (safer WAV parser, Uint8List enforcement)
// FIXED: Updated to use lockStabilityHi/Lo instead of lockStability/unlockStability

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'shims.dart'; // provides FFmpegKit/ReturnCode shim

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'genre_config.dart';
import 'bpm_estimator.dart';
import 'key_detector.dart';
import 'calibration_tools.dart';
import 'bpm_calibrated.dart';
import 'logger.dart';
import 'num_extensions.dart'; // ✅ NEW: Shared extension

class OfflineFileAnalyzerPage extends StatefulWidget {
  const OfflineFileAnalyzerPage({super.key});

  @override
  State<OfflineFileAnalyzerPage> createState() =>
      _OfflineFileAnalyzerPageState();
}

class _OfflineFileAnalyzerPageState extends State<OfflineFileAnalyzerPage> {
  String? _pickedPath;
  String? _wavOut;
  double _progress = 0.0;
  bool _busy = false;
  String? _error;

  Genre _genre = Genre.auto;
  Subgenre _subgenre = Subgenre.none;
  final TextEditingController _hintCtrl = TextEditingController();
  bool _useHint = false;
  bool _useTight = false;

  late BpmEstimator _bpm;
  late KeyDetector _key;
  int _sampleRate = 44100;

  double? _finalBpm;
  double _bpmConf = 0.0;
  double _bpmStab = 0.0;
  bool _bpmLocked = false;

  String _keyLabel = '--';
  double _keyConf = 0.0;
  double? _tuning;

  final HarmoniQLogger _logger = HarmoniQLogger();
  String _testId = '';
  DateTime _start = DateTime.now();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await GenreConfigManager().initialize();
    await _logger.initialize(enableConsole: true, enableFile: true);
    _buildAnalyzers(sampleRate: _sampleRate);
  }

  @override
  void dispose() {
    _hintCtrl.dispose();
    try {
      _key.dispose();
    } catch (_) {} // be safe if not initialized
    _logger.close();
    super.dispose();
  }

  double? get _hintBpm =>
      _useHint ? double.tryParse(_hintCtrl.text.trim()) : null;

  void _buildAnalyzers({required int sampleRate}) {
    // Prevent analyzer leak when rebuilding
    try {
      _key.dispose();
    } catch (_) {}

    _key = KeyDetector(
      sampleRate: sampleRate,
      fftSize: 4096,
      hop: 1024,
      minHz: 30,
      maxHz: 5000,
    );

    final rec = HintCalibrator(
      hintBpm: _hintBpm,
      bandTightness:
      _hintBpm == null ? HintBandTightness.loose : HintBandTightness.medium,
      defaultMinBpm: 60,
      defaultMaxBpm: 190,
    ).recommend();

    // FIXED: Updated parameter names to match new EstimatorBuildArgs
    final args = EstimatorBuildArgs(
      sampleRate: sampleRate,
      frameSize: 1024,
      windowSeconds: 12.0,
      emaAlpha: 0.12,
      historyLength: 36,
      useSpectralFlux: true,
      onsetSensitivity: 0.9,
      medianFilterSize: 9,
      adaptiveThresholdRatio: 1.7,
      hypothesisDecay: 0.97,
      switchThreshold: 1.35,
      switchHoldFrames: 4,
      lockStabilityHi: 0.78, // Was: lockStability
      lockStabilityLo: 0.62, // Was: unlockStability
      beatsToLock: 4.5, // NEW: required parameter
      beatsToUnlock: 2.5, // NEW: required parameter
      reportDeadbandUnlocked: 0.04,
      reportDeadbandLocked: 0.20,
      reportQuantUnlocked: 0.02,
      reportQuantLocked: 0.08,
      minEnergyDb: -65.0,
      fallbackMinBpm: 60,
      fallbackMaxBpm: 190,
    );

    final recTight = _useTight
        ? HintCalibrator(hintBpm: _hintBpm).finalizeTightening(rec)
        : rec;

    _bpm = CalibratedEstimator.fromRecommendation(rec: recTight, args: args);
  }

  Future<void> _pickFile() async {
    setState(() {
      _error = null;
      _progress = 0.0;
      _finalBpm = null;
      _keyLabel = '--';
      _keyConf = 0.0;
      _tuning = null;
    });

    final res = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const [
        'mp3',
        'm4a',
        'aac',
        'wav',
        'flac',
        'aif',
        'aiff',
        'ogg',
      ],
    );
    if (res == null || res.files.isEmpty) return;

    final sel = res.files.single;
    final path = sel.path;
    if (path == null || path.isEmpty) {
      setState(() => _error = 'Could not read selected file path.');
      return;
    }

    _pickedPath = path;
    if (mounted) setState(() {});
  }

  Future<void> _analyze() async {
    if (_pickedPath == null) {
      setState(() => _error = 'Pick an audio file first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0.0;
      _testId = 'file_${DateTime.now().millisecondsSinceEpoch}';
      _start = DateTime.now();
    });

    StreamSubscription<List<int>>? streamSub;

    try {
      // 1) Decode to WAV mono 44.1k PCM16
      final docs = await getApplicationDocumentsDirectory();
      final outDir = p.join(docs.path, 'harmoniq_temp');
      await Directory(outDir).create(recursive: true);
      final wavOut = p.join(
        outDir,
        'decode_${DateTime.now().millisecondsSinceEpoch}.wav',
      );

      final cmd = [
        '-y',
        '-i',
        _pickedPath!,
        '-vn',
        '-ac',
        '1',
        '-ar',
        '44100',
        '-acodec',
        'pcm_s16le',
        '-f',
        'wav',
        wavOut,
      ].map((e) => (e.contains(' ') ? '"$e"' : e)).join(' ');

      final sess = await FFmpegKit.execute(cmd).timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          throw TimeoutException('FFmpeg decode timeout after 120 seconds');
        },
      );

      final rc = await sess.getReturnCode().timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
        throw TimeoutException('FFmpeg return code retrieval timeout'),
      );

      if (!ReturnCode.isSuccess(rc)) {
        final logs = await sess.getAllLogsAsString().timeout(
          const Duration(seconds: 5),
          onTimeout: () => '(log retrieval timeout)',
        );
        setState(() => _error = 'FFmpeg decode failed: $rc\n$logs');
        setState(() => _busy = false);
        return;
      }
      _wavOut = wavOut;

      // 2) Prepare analyzers
      _sampleRate = 44100;
      _buildAnalyzers(sampleRate: _sampleRate);
      await _key.switchGenre(_genre, subgenre: _subgenre);

      // 3) Stream PCM from WAV with safe parser
      final dataOffset = await _wavDataOffsetSafe(_wavOut!);
      final file = File(_wavOut!);
      final totalBytes = await file.length();

      final rawDataBytes = totalBytes - dataOffset;
      final dataBytes = rawDataBytes.isEven ? rawDataBytes : rawDataBytes - 1;
      if (dataBytes <= 0) {
        throw Exception('Invalid WAV file: no data');
      }

      final stream = file.openRead(dataOffset, dataOffset + dataBytes);
      int processed = 0;

      streamSub = stream.listen((chunk) {
        Uint8List bytes =
        (chunk is Uint8List) ? chunk : Uint8List.fromList(chunk);
        if (bytes.isEmpty) return;

        // Ensure even # of bytes for 16-bit samples
        if (bytes.length.isOdd) {
          bytes = bytes.sublist(0, bytes.length - 1);
        }
        if (bytes.isEmpty) return;

        _bpm.addBytes(bytes, channels: 1, isFloat32: false);
        _key.addBytes(bytes, channels: 1, isFloat32: false);

        processed += bytes.length;
        final pct = (processed / dataBytes).clamp(0.0, 1.0).asDouble;
        if (mounted) setState(() => _progress = pct);
      });

      await streamSub.asFuture();

      // 4) Collect final results
      final rawBpm = _bpm.bpm;
      final refined = rawBpm;

      if (mounted) {
        setState(() {
          _finalBpm = refined;
          _bpmConf = _bpm.confidence;
          _bpmStab = _bpm.stability;
          _bpmLocked = _bpm.isLocked;

          _keyLabel = _key.label;
          _keyConf = _key.confidence.clamp(0, 1.0);
          _tuning = _key.tuningOffset;
        });
      }

      // 5) Log
      final analysisMs =
      DateTime.now().difference(_start).inMilliseconds.toDouble();
      final entry = TestLogEntry(
        timestamp: DateTime.now(),
        testType: TestType.mediumTerm,
        testId: _testId,
        audioSource: p.basename(_pickedPath!),
        sourceType: 'file',
        genre: _genre.name,
        subgenre: _subgenre.name,
        modelUsed: _key.modelUsed,
        fallbackModel: _key.fallbackModel,
        classicalEnabled: _key.currentConfig.useClassical,
        classicalWeight: _key.currentConfig.classicalWeight,
        detectedBpm: _finalBpm,
        bpmStability: _bpmStab,
        bpmConfidence: _bpmConf,
        bpmLocked: _bpmLocked,
        detectedKey: _keyLabel,
        keyConfidence: _keyConf,
        topThreeKeys: _key.topAlternates.map((a) => a.label).toList(),
        topThreeConfidences: _key.topAlternates.map((a) => a.score).toList(),
        tuningOffset: _tuning,
        smoothingType: _key.currentConfig.smoothingType.name,
        smoothingStrength: _key.currentConfig.smoothingStrength,
        processingLatency: analysisMs,
        droppedFrames: 0,
        whiteningAlpha: _key.currentConfig.whiteningAlpha,
        bassSuppression: _key.currentConfig.bassSuppression,
        hpcpBins: _key.currentConfig.hpcpBins,
      );
      await _logger.logTestResult(entry);

      // Cleanup temp file (happy path)
      try {
        await File(_wavOut!).delete();
      } catch (_) {}
      _wavOut = null;
    } on TimeoutException catch (e) {
      if (mounted) {
        setState(
                () => _error = 'Timeout: ${e.message ?? "FFmpeg took too long"}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Analysis error: $e');
      }
    } finally {
      await streamSub?.cancel();
      // Always cleanup temp WAV on exit (even if errors)
      if (_wavOut != null) {
        try {
          await File(_wavOut!).delete();
        } catch (_) {}
        _wavOut = null;
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Safe WAV parser with proper chunk scanning and alignment
  Future<int> _wavDataOffsetSafe(String wavPath) async {
    final f = File(wavPath);
    final raf = await f.open();
    try {
      final hdr = await raf.read(12);
      if (hdr.length < 12) return 44;
      final riff = String.fromCharCodes(hdr.sublist(0, 4));
      final wave = String.fromCharCodes(hdr.sublist(8, 12));
      if (riff != 'RIFF' || wave != 'WAVE') return 44;

      int offset = 12;
      while (true) {
        final h = await raf.read(8);
        if (h.length < 8) break;
        final id = String.fromCharCodes(h.sublist(0, 4));
        final size = _le32(h, 4);
        if (id == 'data') return offset + 8;
        offset += 8 + size;
        await raf.setPosition(offset);
        if (size.isOdd) {
          await raf.read(1);
          offset += 1;
        }
        if (offset > 1024 * 1024) break; // header sanity
      }
      return 44;
    } catch (e) {
      debugPrint('WAV header parse error: $e');
      return 44; // fallback to standard offset
    } finally {
      await raf.close();
    }
  }

  int _le32(Uint8List b, int i) {
    if (i + 3 >= b.length) return 0;
    return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
  }

  Future<void> _exportLogs() async {
    await _logger.exportResults(asJson: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Logs exported (JSON)')),
    );
  }

  List<Subgenre> _subsFor(Genre g) {
    switch (g) {
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
        return [Subgenre.none, Subgenre.traditional, Subgenre.modernCountry];
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

  @override
  Widget build(BuildContext context) {
    final fileLabel =
    _pickedPath == null ? 'No file selected' : p.basename(_pickedPath!);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline Track Analyzer'),
        actions: [
          IconButton(
            tooltip: 'Export Logs',
            onPressed: _busy ? null : _exportLogs,
            icon: const Icon(Icons.download),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Card(
                color: Colors.red.withValues(alpha: 0.12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Source File',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            fileLabel,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _pickFile,
                          icon: const Icon(Icons.attach_file),
                          label: const Text('Pick'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<Genre>(
                            value: _genre,
                            decoration: const InputDecoration(
                              labelText: 'Genre',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: Genre.values
                                .map(
                                  (g) => DropdownMenuItem(
                                value: g,
                                child: Text(g.name),
                              ),
                            )
                                .toList(),
                            onChanged: _busy
                                ? null
                                : (g) {
                              if (g == null) return;
                              setState(() {
                                _genre = g;
                                _subgenre = Subgenre.none;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<Subgenre>(
                            value: _subgenre,
                            decoration: const InputDecoration(
                              labelText: 'Subgenre',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: _subsFor(_genre)
                                .map(
                                  (s) => DropdownMenuItem(
                                value: s,
                                child: Text(s.name.replaceAll('_', ' ')),
                              ),
                            )
                                .toList(),
                            onChanged: _busy
                                ? null
                                : (s) {
                              if (s == null) return;
                              setState(() => _subgenre = s);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      title: const Text('Use Hint BPM'),
                      value: _useHint,
                      onChanged:
                      _busy ? null : (v) => setState(() => _useHint = v),
                      subtitle: const Text('Constrain search range'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (_useHint)
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _hintCtrl,
                              keyboardType:
                              const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Hint BPM',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              enabled: !_busy,
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _busy
                                ? null
                                : () => setState(
                                  () => _buildAnalyzers(
                                sampleRate: _sampleRate,
                              ),
                            ),
                            child: const Text('Apply'),
                          ),
                        ],
                      ),
                    SwitchListTile(
                      title: const Text('Tighten after lock'),
                      value: _useTight,
                      onChanged:
                      _busy ? null : (v) => setState(() => _useTight = v),
                      subtitle: const Text('Narrow range when stable'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed:
                      (_pickedPath != null && !_busy) ? _analyze : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Analyze Track'),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _busy ? _progress : 0.0,
                      minHeight: 8,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Results',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    _ResultRow(
                      label: 'BPM',
                      value: _finalBpm == null
                          ? '--'
                          : '${_finalBpm!.toStringAsFixed(1)} BPM',
                    ),
                    _ResultRow(
                      label: 'Confidence',
                      value: '${(_bpmConf * 100).toStringAsFixed(0)}%',
                    ),
                    _ResultRow(
                      label: 'Stability',
                      value: '${(_bpmStab * 100).toStringAsFixed(0)}%',
                    ),
                    _ResultRow(
                      label: 'Locked',
                      value: _bpmLocked ? 'Yes' : 'No',
                    ),
                    const Divider(),
                    _ResultRow(label: 'Key', value: _keyLabel),
                    _ResultRow(
                      label: 'Key Confidence',
                      value: '${(_keyConf * 100).toStringAsFixed(0)}%',
                    ),
                    _ResultRow(
                      label: 'Tuning',
                      value: _tuning == null
                          ? '--'
                          : '${_tuning! > 0 ? '+' : ''}${_tuning!.toStringAsFixed(1)}¢',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Model: ${_key.modelUsed.split('/').last}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
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
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}