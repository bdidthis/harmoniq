import 'bpm_test_page.dart';
import 'package:flutter/material.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'ffmpeg_shim.dart';
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: BpmTestPage()));
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

  // Live input level + debug stats
  double _level = 0.0;   // smoothed 0..1 for UI
  double _lastRms = 0.0; // raw RMS 0..1
  double _peakDbfs = -120.0;

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
  static const int _sampleRate = 48000; // macOS often prefers 48 kHz

  final List<double> _rolling = List.filled(_fftSize, 0.0, growable: false);
  int _rollIndex = 0;

  List<double> _spectrum = List.filled(_fftSize ~/ 2, 0.0, growable: false);
  Timer? _throttleTimer;

  // Chroma accumulation for key detection
  final List<double> _chroma = List.filled(12, 0.0, growable: false);
  double _energyAccum = 0.0;

  // Debug counters
  int _frameCount = 0;

  // ===== Device picking =====
  List<InputDevice> _devices = [];
  InputDevice? _selectedDevice;

  // ===== File analysis =====
  bool _isAnalyzingFile = false;
  double _fileProgress = 0.0;
  String? _fileName;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    try {
      final list = await _recorder.listInputDevices();
      list.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      InputDevice? picked = list.firstWhere(
            (d) => d.label.toLowerCase().contains('macbook') ||
            d.label.toLowerCase().contains('built-in'),
        orElse: () => list.isNotEmpty ? list.first : InputDevice(id: '', label: ''),
      );
      if (picked.id.isEmpty) picked = null;

      setState(() {
        _devices = list;
        _selectedDevice = picked ?? (_devices.isNotEmpty ? _devices.first : null);
      });

      debugPrint('[harmoniQ] Input devices:');
      for (final d in list) {
        debugPrint(' - ${d.label} (${d.id})');
      }
      debugPrint('[harmoniQ] Selected: ${_selectedDevice?.label ?? "(none)"}');
    } catch (e) {
      debugPrint('[harmoniQ] loadDevices error: $e');
    }
  }

  @override
  void dispose() {
    _bpmCtrl.dispose();
    _tapResetTimer?.cancel();
    _audioSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  // ===== Shared reset =====
  void _resetAnalysis() {
    for (int i = 0; i < 12; i++) _chroma[i] = 0.0;
    _energyAccum = 0.0;
    _level = 0.0;
    _lastRms = 0.0;
    _peakDbfs = -120.0;
    _frameCount = 0;
    _smoothFreq = 0.0;
    _liveFreq = 0.0;
    _liveNote = '--';
    _keyResult = '--';
    _confidence = 0.0;
    _spectrum = List.filled(_fftSize ~/ 2, 0.0, growable: false);
  }

  // ===== Analyze control =====
  Future<void> _onPressStart() async {
    try {
      debugPrint('[harmoniQ] START pressed (device: ${_selectedDevice?.label})');

      _resetAnalysis();

      if (!await _recorder.hasPermission()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
        return;
      }

      final cfg = RecordConfig(
        encoder: AudioEncoder.pcm16bits,   // we also auto-detect at read-time
        sampleRate: _sampleRate,
        numChannels: _channels,
        device: _selectedDevice,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      );

      final stream = await _recorder.startStream(cfg);

      await _audioSub?.cancel();
      _audioSub = stream.listen(_onAudioBytes, onError: (e, _) {
        debugPrint('[harmoniQ] Audio error: $e');
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Audio error: $e')));
      });

      debugPrint('[harmoniQ] Subscribed to audio stream');
      setState(() => _isRecording = true);
    } catch (e) {
      debugPrint('[harmoniQ] Start error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Start error: $e')));
    }
  }

  Future<void> _onPressEnd() async {
    debugPrint('[harmoniQ] STOP pressed');
    try {
      await _audioSub?.cancel();
      _audioSub = null;
      await _recorder.stop();
    } catch (_) {}

    final detection = _detectKeyFromChroma(_chroma, _energyAccum);
    setState(() {
      _isRecording = false;
      _keyResult = detection.keyLabel;
      _confidence = detection.confidence;
    });
  }

  // ===== Stream callback with Int16/Float32 auto-detect =====
  void _onAudioBytes(Uint8List bytes) {
    if (bytes.isEmpty) return;

    _frameCount++;
    if (_frameCount % 20 == 0) {
      debugPrint('[harmoniQ] frames: $_frameCount bytes: ${bytes.length}');
    }

    final bd = ByteData.sublistView(bytes);

    // ---- Try Int16 decode ----
    double sumSq16 = 0.0;
    double peakAbs16 = 0.0;
    final n16 = bd.lengthInBytes ~/ 2;
    for (int i = 0; i < n16; i++) {
      final f = bd.getInt16(i * 2, Endian.little) / 32768.0;
      sumSq16 += f * f;
      final a = f.abs();
      if (a > peakAbs16) peakAbs16 = a;
    }
    final rms16 = n16 == 0 ? 0.0 : math.sqrt(sumSq16 / n16);

    // ---- Try Float32 decode ----
    double sumSqF32 = 0.0;
    double peakAbs32 = 0.0;
    final n32 = bd.lengthInBytes ~/ 4;
    for (int i = 0; i < n32; i++) {
      final fc = bd.getFloat32(i * 4, Endian.little).clamp(-1.0, 1.0);
      sumSqF32 += fc * fc;
      final a = fc.abs();
      if (a > peakAbs32) peakAbs32 = a;
    }
    final rms32 = n32 == 0 ? 0.0 : math.sqrt(sumSqF32 / n32);

    // Choose interpretation with larger RMS
    final useF32 = rms32 > (rms16 * 1.2);
    _lastRms = useF32 ? rms32 : rms16;
    final peak = useF32 ? peakAbs32 : peakAbs16;
    _peakDbfs = peak > 0 ? 20 * math.log(peak) / math.ln10 : -120.0;

    // UI level (softer gain)
    final shown = (_lastRms * 1.2).clamp(0.0, 1.0);
    _level = (_level * 0.8) + (shown * 0.2);

    // ---- Feed rolling buffer (2x preamp) ----
    if (useF32 && n32 > 0) {
      for (int i = 0; i < n32; i++) {
        final s = (bd.getFloat32(i * 4, Endian.little).clamp(-1.0, 1.0) * 2.0)
            .clamp(-1.0, 1.0);
        _rolling[_rollIndex] = s;
        _rollIndex = (_rollIndex + 1) % _rolling.length;
        _energyAccum += s * s;
      }
    } else if (n16 > 0) {
      for (int i = 0; i < n16; i++) {
        final s = ((bd.getInt16(i * 2, Endian.little) / 32768.0) * 2.0)
            .clamp(-1.0, 1.0);
        _rolling[_rollIndex] = s;
        _rollIndex = (_rollIndex + 1) % _rolling.length;
        _energyAccum += s * s;
      }
    }

    // throttle ~20 fps (still refresh stats)
    if (_throttleTimer != null && _throttleTimer!.isActive) {
      if (mounted) setState(() {});
      return;
    }
    _throttleTimer = Timer(const Duration(milliseconds: 50), () {});

    // Build FFT window from rolling buffer
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
      mags[k] = math.sqrt(n.clamp(0.0, 1.0));
    }

    // accumulate chroma for key detection
    _accumulateChromaFromSpectrum(mags);

    // live pitch (dominant bin)
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

    _smoothFreq = _smoothFreq == 0 ? freq : (_smoothFreq * 0.8 + freq * 0.2);
    final note = _freqToNoteName(_smoothFreq);

    if (!mounted) return;
    setState(() {
      _spectrum = mags;
      _liveFreq = _smoothFreq;
      _liveNote = note;
    });
  }

  // ===== File import / analysis =====
  Future<void> _pickAndAnalyzeFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'wav','aif','aiff','flac','ogg','mp3','m4a','aac','mp4','mov','mkv'
        ],
      );
      if (res == null || res.files.isEmpty || res.files.single.path == null) return;
      final inputPath = res.files.single.path!;
      _fileName = res.files.single.name;

      await _analyzeAudioFile(inputPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('File pick error: $e')));
    }
  }

  Future<void> _analyzeAudioFile(String inputPath) async {
    _resetAnalysis();
    setState(() { _isAnalyzingFile = true; _fileProgress = 0.0; });

    try {
      final tmpDir = await getTemporaryDirectory();
      final outPath = '${tmpDir.path}/harmoniq_decoded.wav';

      // Decode to mono, 48kHz, 16-bit PCM WAV
      final cmd = '-y -i ${_ffArg(inputPath)} -vn -ac 1 -ar $_sampleRate '
          '-sample_fmt s16 ${_ffArg(outPath)}';
      debugPrint('[harmoniQ] ffmpeg: $cmd');
      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) {
        final logs = await session.getAllLogsAsString();
        throw 'ffmpeg failed: $rc\n$logs';
      }

      final file = File(outPath);
      final raf = await file.open();
      final totalLen = await raf.length();

      // Parse minimal WAV header to find data offset
      final header = await raf.read(128);
      int dataOffset = _findWavDataOffset(header);
      if (dataOffset <= 0) dataOffset = 44; // fallback
      await raf.setPosition(dataOffset);

      int processed = dataOffset;
      const chunkSize = 4096;

      // Animate progress + reuse same processing path
      while (true) {
        final chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;
        _onAudioBytes(chunk);
        processed += chunk.length;
        if (processed % (chunkSize * 16) == 0) {
          setState(() => _fileProgress = (processed / totalLen).clamp(0.0, 1.0));
          await Future.delayed(const Duration(milliseconds: 5));
        }
      }
      await raf.close();

      // Finish / compute key
      final detection = _detectKeyFromChroma(_chroma, _energyAccum);
      setState(() {
        _keyResult = detection.keyLabel;
        _confidence = detection.confidence;
        _fileProgress = 1.0;
        _isAnalyzingFile = false;
      });
    } catch (e) {
      debugPrint('[harmoniQ] File analyze error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Analyze error: $e')));
      setState(() => _isAnalyzingFile = false);
    }
  }

  String _ffArg(String p) => '"${p.replaceAll('"', r'\"')}"';

  int _findWavDataOffset(Uint8List head) {
    // naive RIFF scan for "data" chunk
    for (int i = 0; i <= head.length - 8; i++) {
      if (head[i] == 0x64 && head[i + 1] == 0x61 && head[i + 2] == 0x74 && head[i + 3] == 0x61) {
        // "data"
        final size = head[i + 4] |
        (head[i + 5] << 8) |
        (head[i + 6] << 16) |
        (head[i + 7] << 24);
        return i + 8; // start of PCM
      }
    }
    return -1;
  }

  // ===== Chroma accumulation from spectrum =====
  void _accumulateChromaFromSpectrum(List<double> mags) {
    for (int k = 1; k < mags.length; k++) {
      final f = (k * _sampleRate) / _fftSize;
      if (f < 50 || f > 5000) continue;
      final w = mags[k];
      if (w <= 0) continue;
      final midi = 69 + 12 * (math.log(f / 440.0) / math.ln2);
      int pc = midi.round() % 12;
      pc = (pc + 12) % 12;
      _chroma[pc] += w;
    }
  }

  // ===== Tap tempo & durations =====
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
            // DEVICE PICKER + FILE IMPORT
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.settings_input_component),
                        const SizedBox(width: 8),
                        const Text('Input'),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButton<InputDevice>(
                            isExpanded: true,
                            value: _selectedDevice,
                            hint: const Text('Select input device'),
                            items: _devices.map((d) {
                              return DropdownMenuItem(
                                value: d,
                                child: Text(d.label),
                              );
                            }).toList(),
                            onChanged: (v) => setState(() => _selectedDevice = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Refresh devices',
                          onPressed: _loadDevices,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.audiotrack),
                            label: const Text('Analyze audio file'),
                            onPressed: _isAnalyzingFile ? null : _pickAndAnalyzeFile,
                          ),
                        ),
                      ],
                    ),
                    if (_isAnalyzingFile) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _fileName == null ? 'Analyzing file…' : 'Analyzing: $_fileName',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: _fileProgress == 0 ? null : _fileProgress),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

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
            const SizedBox(height: 12),

            // Mic controls: press/hold + toggle
            Center(
              child: Column(
                children: [
                  PressHoldMicButton(
                    isRecording: _isRecording,
                    onPressStart: _onPressStart,
                    onPressEnd: _onPressEnd,
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _isRecording ? _onPressEnd : _onPressStart,
                    icon: Icon(_isRecording ? Icons.stop : Icons.play_arrow),
                    label: Text(_isRecording ? 'Stop' : 'Start (toggle)'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Live input level + frame counter + stats
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.graphic_eq),
                      const SizedBox(width: 8),
                      const Text('Mic level'),
                      const Spacer(),
                      Text('${(_level * 100).clamp(0, 100).toStringAsFixed(0)}%'),
                    ]),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: _level.clamp(0.0, 1.0),
                        minHeight: 10,
                        backgroundColor: Colors.white12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Frames: $_frameCount'),
                    Text('RMS: ${_lastRms.toStringAsFixed(3)} | peak: ${_peakDbfs.toStringAsFixed(1)} dBFS'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

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

  // ===== Key detection (Krumhansl) =====
  _KeyDetectionResult _detectKeyFromChroma(List<double> chroma, double energy) {
    if (energy < 1e-3) return const _KeyDetectionResult('--', 0.0);

    final c = List<double>.from(chroma);
    final sum = c.fold<double>(0.0, (a, b) => a + b);
    if (sum <= 1e-9) return const _KeyDetectionResult('--', 0.0);
    for (int i = 0; i < 12; i++) c[i] /= sum;

    const major = [6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88];
    const minor = [6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17];

    List<double> _norm(List<double> v) {
      final s = math.sqrt(v.fold<double>(0.0, (a, b) => a + b*b));
      return v.map((x) => x / (s == 0 ? 1 : s)).toList();
    }
    final majN = _norm(major);
    final minN = _norm(minor);
    final cN = _norm(c);

    const names = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'];

    double bestScore = -1.0, second = -1.0;
    String bestLabel = '--';

    double dot(List<double> a, List<double> b) {
      double s = 0;
      for (int i = 0; i < 12; i++) s += a[i] * b[i];
      return s;
    }

    List<double> rotate(List<double> v, int shift) {
      final out = List<double>.filled(12, 0);
      for (int i = 0; i < 12; i++) {
        out[i] = v[(i - shift) % 12 < 0 ? (i - shift + 12) % 12 : (i - shift) % 12];
      }
      return out;
    }

    for (int s = 0; s < 12; s++) {
      final dMaj = dot(cN, rotate(majN, s));
      final dMin = dot(cN, rotate(minN, s));

      void consider(double score, String label) {
        if (score > bestScore) {
          second = bestScore;
          bestScore = score;
          bestLabel = label;
        } else if (score > second) {
          second = score;
        }
      }

      consider(dMaj, '${names[s]} major');
      consider(dMin, '${names[s]} minor');
    }

    final sep = (bestScore - (second < 0 ? 0 : second)).clamp(0.0, 1.0);
    final conf = (0.7 * bestScore + 0.3 * sep).clamp(0.0, 1.0);

    return _KeyDetectionResult(bestLabel, conf);
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
    for (; (j & bit) != 0; bit >>= 1) {
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

// Small result card
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

// Key detection result
class _KeyDetectionResult {
  final String keyLabel;
  final double confidence; // 0..1
  const _KeyDetectionResult(this.keyLabel, this.confidence);
}
