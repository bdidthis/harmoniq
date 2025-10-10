// lib/bpm_test_page.dart
// Fixed: Removed estimator_factory import, aligned with correct BpmEstimator

import 'dart:async';
import 'dart:convert' show ascii;
import 'dart:io' show Platform, File;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:path_provider/path_provider.dart';
import 'package:audio_session/audio_session.dart' as asess;
import 'package:permission_handler/permission_handler.dart';

import 'bpm_estimator.dart';
import 'music_math.dart';
import 'key_detector.dart';

class BpmTestPage extends StatefulWidget {
  const BpmTestPage({super.key, this.onSetAppBpm});
  final void Function(double bpm)? onSetAppBpm;

  @override
  State<BpmTestPage> createState() => _BpmTestPageState();
}

class _BpmTestPageState extends State<BpmTestPage> {
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  StreamSubscription<RecordState>? _stateSub;

  int _sampleRate = 48000;
  static const int _channels = 1;

  late BpmEstimator _bpm = BpmEstimator(sampleRate: _sampleRate);
  late KeyDetector _key;
  String _keyLabel = '--';
  double _keyConf = 0.0;

  double? _bpmNow;
  double _rms = 0.0;
  bool _on = false;

  int _dbgCount = 0;
  int _chunks = 0;
  int _lastChunkBytes = 0;
  String _recState = 'idle';
  String _lastCfg = '';
  String _permNote = '';

  double? _tapBpm;
  final TextEditingController _manualBpmCtrl = TextEditingController();

  final ap.AudioPlayer _clickPlayer = ap.AudioPlayer();
  final ap.AudioPlayer _accentPlayer = ap.AudioPlayer();
  Timer? _metroTimer;
  bool _metroOn = false;
  int _metroBeat = 0;
  Uint8List? _clickWav;
  Uint8List? _accentWav;

  void _roundTap(double step) {
    if (_tapBpm == null) return;
    setState(() => _tapBpm = ((_tapBpm! / step).round() * step));
  }

  Future<void> _copyTap() async {
    if (_tapBpm == null) return;
    await Clipboard.setData(ClipboardData(text: _tapBpm!.toStringAsFixed(1)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${_tapBpm!.toStringAsFixed(1)} BPM')),
    );
  }

  void _applyManual() {
    final v = double.tryParse(_manualBpmCtrl.text);
    if (v == null || v <= 0) return;
    setState(() => _bpmNow = v);
  }

  String _delayTableToText(double bpm) {
    final rows = delayTableForBpm(bpm);
    final sb = StringBuffer('${bpm.toStringAsFixed(1)} BPM\n');
    for (final r in rows) {
      sb.writeln('${r.label}\t${r.ms.toStringAsFixed(1)} ms');
    }
    return sb.toString();
  }

  Future<void> _copyDelayTable() async {
    final bpm = _bpmNow ?? _tapBpm;
    if (bpm == null) return;
    final txt = _delayTableToText(bpm);
    await Clipboard.setData(ClipboardData(text: txt));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied delay table for ${bpm.toStringAsFixed(1)} BPM'),
      ),
    );
  }

  Future<void> _saveDelayTableTxt() async {
    final bpm = _bpmNow ?? _tapBpm;
    if (bpm == null) return;
    final dir = await getTemporaryDirectory();
    final name =
        'delay_table_${bpm.toStringAsFixed(1)}bpm_${DateTime.now().millisecondsSinceEpoch}.txt';
    final path = '${dir.path}/$name';
    final txt = _delayTableToText(bpm);
    final f = File(path);
    await f.writeAsString(txt);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved: $path')));
  }

  @override
  void initState() {
    super.initState();
    _key = KeyDetector(sampleRate: _sampleRate);
    _stateSub = _rec.onStateChanged().listen((s) {
      if (mounted) setState(() => _recState = s.toString().split('.').last);
    });
    _initMetronome();
  }

  @override
  void dispose() {
    _stopMetronome();
    _manualBpmCtrl.dispose();
    _sub?.cancel();
    _stateSub?.cancel();
    _rec.stop();
    _rec.dispose();
    _releasePlayers();
    _key.dispose();
    super.dispose();
  }

  Future<bool> _ensureMicPermission() async {
    PermissionStatus? sysStatus;
    try {
      sysStatus = await Permission.microphone.status;
      if (mounted)
        setState(
          () =>
              _permNote = 'perm(sys): ${sysStatus.toString().split('.').last}',
        );
      if (sysStatus.isDenied || sysStatus.isRestricted || sysStatus.isLimited) {
        sysStatus = await Permission.microphone.request();
        if (mounted)
          setState(
            () => _permNote =
                'perm(req): ${sysStatus.toString().split('.').last}',
          );
      }
    } catch (_) {}

    bool recOk = false;
    try {
      recOk = await _rec.hasPermission();
      if (mounted) {
        _permNote += recOk ? '  rec:granted' : '  rec:denied';
        setState(() {});
      }
    } catch (_) {}

    if ((sysStatus?.isGranted ?? false) || recOk) return true;

    if (sysStatus?.isPermanentlyDenied ?? false) {
      if (!mounted) return false;
      final open = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Microphone Permission Needed'),
          content: const Text(
            'Enable microphone access for this app in Settings → Privacy & Security → Microphone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      if (open == true) await openAppSettings();
      return false;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission not granted')),
      );
    }
    return false;
  }

  Future<void> _pausePlayersForRecording() async {
    try {
      await _clickPlayer.stop();
      await _accentPlayer.stop();
    } catch (_) {}
  }

  Future<void> _start() async {
    final permOk = await _ensureMicPermission();
    if (!permOk) return;

    await _pausePlayersForRecording();

    if (Platform.isIOS) {
      final session = await asess.AudioSession.instance;
      await session.configure(
        asess.AudioSessionConfiguration(
          avAudioSessionCategory: asess.AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              asess.AVAudioSessionCategoryOptions.defaultToSpeaker |
                  asess.AVAudioSessionCategoryOptions.allowBluetooth,
          avAudioSessionMode: asess.AVAudioSessionMode.measurement,
          avAudioSessionRouteSharingPolicy:
              asess.AVAudioSessionRouteSharingPolicy.defaultPolicy,
          avAudioSessionSetActiveOptions:
              asess.AVAudioSessionSetActiveOptions.none,
          androidAudioAttributes: const asess.AndroidAudioAttributes(
            contentType: asess.AndroidAudioContentType.music,
            flags: asess.AndroidAudioFlags.none,
            usage: asess.AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: asess.AndroidAudioFocusGainType.gain,
          androidWillPauseWhenDucked: true,
        ),
      );
      await session.setActive(true);
    }

    final configs = <RecordConfig>[
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 48000,
        numChannels: 1,
      ),
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
      ),
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 32000,
        numChannels: 1,
      ),
    ];

    bool started = false;
    for (final cfg in configs) {
      started = await _tryStartWithConfig(cfg);
      if (started) break;
    }

    if (!started && mounted) {
      final hint = Platform.isIOS
          ? 'Check Settings → Privacy & Security → Microphone and ensure the app is enabled. If it is, force-quit and relaunch.'
          : 'Some emulators do not pass mic audio. Try a real device.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('No mic audio. $hint')));
    }
  }

  Future<bool> _tryStartWithConfig(RecordConfig cfg) async {
    await _sub?.cancel();
    await _rec.stop();

    _chunks = 0;
    _lastChunkBytes = 0;
    _lastCfg = 'pcm16  sr=${cfg.sampleRate}  ch=${cfg.numChannels}';

    try {
      final stream = await _rec.startStream(cfg);
      _sub = stream.listen(
        _onBytes,
        onError: (e) => debugPrint('rec stream error: $e'),
        onDone: () => debugPrint('rec stream done'),
        cancelOnError: true,
      );
    } catch (e) {
      return false;
    }

    if (mounted) setState(() => _on = true);

    await Future.delayed(const Duration(milliseconds: 2000));
    final success = _chunks > 0 && _lastChunkBytes > 0;

    if (!success) {
      await _sub?.cancel();
      await _rec.stop();
      if (mounted) setState(() => _on = false);
      return false;
    }

    if (cfg.sampleRate != _sampleRate) {
      _sampleRate = cfg.sampleRate;
      _bpm = BpmEstimator(sampleRate: _sampleRate);
      _key = KeyDetector(sampleRate: _sampleRate);
      _keyLabel = '--';
      _keyConf = 0.0;
      _clickWav = _buildClickWav(
        sampleRate: 44100,
        ms: 12,
        freqHz: 1000,
        amp: 0.8,
      );
      _accentWav = _buildClickWav(
        sampleRate: 44100,
        ms: 16,
        freqHz: 1600,
        amp: 1.0,
      );
      if (mounted) setState(() {});
    }

    return true;
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    await _rec.stop();
    if (mounted) {
      setState(() {
        _on = false;
        _rms = 0.0;
        _bpmNow = null;
        _chunks = 0;
        _lastChunkBytes = 0;
        _keyLabel = '--';
        _keyConf = 0.0;
      });
    }
  }

  void _onBytes(Uint8List bytes) {
    if (bytes.isEmpty) return;

    _chunks++;
    _lastChunkBytes = bytes.lengthInBytes;

    Uint8List b =
        (bytes.offsetInBytes % 2 == 0) ? bytes : Uint8List.fromList(bytes);
    if (b.lengthInBytes.isOdd) b = b.sublist(0, b.lengthInBytes - 1);

    if (b.isNotEmpty) {
      final i16 = b.buffer.asInt16List(0, b.lengthInBytes ~/ 2);
      if (i16.isNotEmpty) {
        double sum = 0.0;
        for (int i = 0; i < i16.length; i++) {
          final s = i16[i] / 32768.0;
          sum += s * s;
        }
        final meanSq = sum / i16.length;
        final rms = meanSq <= 0 ? 0.0 : math.sqrt(meanSq);
        _rms = rms;

        try {
          _bpm.addBytes(b, channels: _channels, isFloat32: false);
          _key.addBytes(b, channels: _channels, isFloat32: false);
          _keyLabel = _key.label;
          _keyConf = _key.confidence;
        } catch (_) {}
      }
    }

    if ((_dbgCount++ % 20) == 0) {
      final s = _bpm.debugStats;
      debugPrint(
        'perm=$_permNote  state=$_recState  cfg=$_lastCfg  chunks=$_chunks last=${_lastChunkBytes}B  '
        'BPM ${_bpm.bpm?.toStringAsFixed(1) ?? "--"}  '
        'env_len ${s["env_len"]}  '
        'energy_db ${(s["energy_db"] as double?)?.toStringAsFixed(1)}  '
        'format ${s["format_guess"]}  '
        'frameRMS ${(s["last_frame_rms"] as double?)?.toStringAsFixed(6)}',
      );
    }

    final val = _bpm.bpm;

    if (!mounted) return;
    setState(() {
      _rms = _rms.clamp(0.0, 1.0);
      if (val != null) _bpmNow = val;
    });
  }

  Future<void> _selfTest120() async {
    final bytes = _genMetronomeBytes(
      bpm: 120.0,
      seconds: 6.0,
      sampleRate: _sampleRate,
      channels: _channels,
      pipMs: 12,
      pipFreqHz: 1000,
      pipAmp: 0.6,
    );

    _chunks = 0;
    _lastChunkBytes = bytes.lengthInBytes;

    _bpm.reset();
    _bpm.addBytes(bytes, channels: _channels, isFloat32: false);

    if (mounted) {
      setState(() {
        _bpmNow = _bpm.bpm;
        _rms = 0.5;
      });
    }
  }

  Uint8List _genMetronomeBytes({
    required double bpm,
    required double seconds,
    required int sampleRate,
    required int channels,
    required int pipMs,
    required int pipFreqHz,
    required double pipAmp,
  }) {
    final totalSamples = (seconds * sampleRate).round();
    final Int16List buf = Int16List(totalSamples * channels);
    final int pipSamples = (pipMs * sampleRate / 1000).round();
    final double beatPeriodSec = 60.0 / bpm;
    final int beatSamples = (beatPeriodSec * sampleRate).round();

    int t = 0;
    while (t < totalSamples) {
      for (int n = 0; n < pipSamples && (t + n) < totalSamples; n++) {
        final double x =
            pipAmp * math.sin(2 * math.pi * pipFreqHz * n / sampleRate);
        final int s = (x * 32767.0).clamp(-32768.0, 32767.0).round();
        final int idx = (t + n) * channels;
        for (int c = 0; c < channels; c++) {
          if (idx + c < buf.length) buf[idx + c] = s;
        }
      }
      t += beatSamples;
    }
    return buf.buffer.asUint8List();
  }

  void _onTapTempoBpm(double? bpm) {
    if (mounted) setState(() => _tapBpm = bpm);
  }

  void _applyTapToTable() {
    if (_tapBpm != null && mounted) setState(() => _bpmNow = _tapBpm);
  }

  void _initMetronome() {
    _clickWav = _buildClickWav(
      sampleRate: 44100,
      ms: 12,
      freqHz: 1000,
      amp: 0.8,
    );
    _accentWav = _buildClickWav(
      sampleRate: 44100,
      ms: 16,
      freqHz: 1600,
      amp: 1.0,
    );
  }

  void _releasePlayers() {
    _clickPlayer.dispose();
    _accentPlayer.dispose();
  }

  double? _currentBpmOrNull() =>
      _bpmNow ?? _tapBpm ?? double.tryParse(_manualBpmCtrl.text);

  void _startMetronome() {
    final bpm = _currentBpmOrNull() ?? 120.0;
    _restartMetronomeWithBpm(bpm);
  }

  void _restartMetronomeWithBpm(double bpm) {
    _stopMetronome();
    final beatMs = 60000.0 / bpm;
    _metroBeat = 0;
    _metroOn = true;

    _metroTimer = Timer.periodic(Duration(milliseconds: beatMs.round()), (_) {
      final isAccent = (_metroBeat % 4) == 0;
      final bytes = isAccent ? _accentWav : _clickWav;
      if (bytes != null) {
        final p = isAccent ? _accentPlayer : _clickPlayer;
        p.stop();
        p.play(ap.BytesSource(bytes));
      }
      _metroBeat++;
    });
    if (mounted) setState(() {});
  }

  void _stopMetronome() {
    _metroTimer?.cancel();
    _metroTimer = null;
    _metroOn = false;
    _clickPlayer.stop();
    _accentPlayer.stop();
    if (mounted) setState(() {});
  }

  Uint8List _buildClickWav({
    required int sampleRate,
    required int ms,
    required int freqHz,
    required double amp,
  }) {
    final int frames = (sampleRate * ms / 1000).round();
    final Int16List pcm = Int16List(frames);
    for (int n = 0; n < frames; n++) {
      final env = math.exp(-5.0 * n / frames);
      final x = amp * env * math.sin(2 * math.pi * freqHz * n / sampleRate);
      pcm[n] = (x * 32767.0).clamp(-32768, 32767).round();
    }
    return _pcm16ToWavBytes(pcm, sampleRate, 1);
  }

  Uint8List _pcm16ToWavBytes(Int16List pcm, int sampleRate, int channels) {
    final int byteRate = sampleRate * channels * 2;
    final int blockAlign = channels * 2;
    final int dataSize = pcm.lengthInBytes;
    final int chunkSize = 36 + dataSize;

    final bytes = BytesBuilder();
    void w32(int v) => bytes.add(
          Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little),
        );
    void w16(int v) => bytes.add(
          Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little),
        );

    bytes.add(ascii.encode('RIFF'));
    w32(chunkSize);
    bytes.add(ascii.encode('WAVE'));

    bytes.add(ascii.encode('fmt '));
    w32(16);
    w16(1);
    w16(channels);
    w32(sampleRate);
    w32(byteRate);
    w16(blockAlign);
    w16(16);

    bytes.add(ascii.encode('data'));
    w32(dataSize);
    bytes.add(pcm.buffer.asUint8List());

    return bytes.toBytes();
  }

  @override
  Widget build(BuildContext context) {
    final level = _rms.isNaN ? 0.0 : _rms.clamp(0.0, 1.0);

    final stats = _bpm.debugStats;
    final envLen = stats['env_len'];
    final energyDb = (stats['energy_db'] is double)
        ? (stats['energy_db'] as double)
        : double.nan;
    final fmt = stats['format_guess'];
    final frameRms = (stats['last_frame_rms'] is double)
        ? (stats['last_frame_rms'] as double)
        : double.nan;

    final double? tableBpm = _bpmNow ?? _tapBpm;

    return Scaffold(
      appBar: AppBar(title: const Text('BPM Test')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        ElevatedButton(
                          onPressed: _on ? _stop : _start,
                          child: Text(_on ? 'Stop Mic' : 'Start Mic'),
                        ),
                        ElevatedButton(
                          onPressed: _selfTest120,
                          child: const Text('Self-Test 120 BPM'),
                        ),
                        Text('state: $_recState'),
                        if (_lastCfg.isNotEmpty) Text(_lastCfg),
                        if (_permNote.isNotEmpty) Text(_permNote),
                      ],
                    ),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: level),
                    const SizedBox(height: 12),
                    Text(
                      _bpmNow == null
                          ? 'BPM: --'
                          : 'BPM: ${_bpmNow!.toStringAsFixed(1)}',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _keyLabel == '--'
                          ? 'Key: --'
                          : 'Key: $_keyLabel (${(_keyConf * 100).toStringAsFixed(0)}%)',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TapTempoPanel(onBpmChanged: _onTapTempoBpm),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Text(
                          'Tap BPM: ${_tapBpm == null ? "--" : _tapBpm!.toStringAsFixed(1)}',
                        ),
                        ElevatedButton(
                          onPressed: _tapBpm == null ? null : _applyTapToTable,
                          child: const Text('Apply to Table'),
                        ),
                        OutlinedButton(
                          onPressed:
                              _tapBpm == null ? null : () => _roundTap(1.0),
                          child: const Text('Round 1'),
                        ),
                        OutlinedButton(
                          onPressed:
                              _tapBpm == null ? null : () => _roundTap(0.5),
                          child: const Text('Round .5'),
                        ),
                        OutlinedButton(
                          onPressed: _tapBpm == null ? null : _copyTap,
                          child: const Text('Copy'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('Manual BPM:'),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 88,
                          child: TextField(
                            controller: _manualBpmCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              hintText: 'e.g. 128',
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _applyManual(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _applyManual,
                          child: const Text('Apply'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Card(
                      elevation: 1,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Metronome',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                ElevatedButton(
                                  onPressed: _metroOn
                                      ? _stopMetronome
                                      : _startMetronome,
                                  child: Text(_metroOn ? 'Stop' : 'Start'),
                                ),
                                OutlinedButton(
                                  onPressed:
                                      !_metroOn && _currentBpmOrNull() != null
                                          ? () => _restartMetronomeWithBpm(
                                                _currentBpmOrNull()!,
                                              )
                                          : null,
                                  child: const Text('Start @ Current BPM'),
                                ),
                                OutlinedButton(
                                  onPressed:
                                      _metroOn && _currentBpmOrNull() != null
                                          ? () => _restartMetronomeWithBpm(
                                                _currentBpmOrNull()!,
                                              )
                                          : null,
                                  child: const Text('Restart (Sync)'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'BPM source → table: ${tableBpm?.toStringAsFixed(1) ?? "--"}, '
                              'tap: ${_tapBpm?.toStringAsFixed(1) ?? "--"}, '
                              'manual: ${double.tryParse(_manualBpmCtrl.text)?.toStringAsFixed(1) ?? "--"}',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: tableBpm == null
                          ? null
                          : () {
                              widget.onSetAppBpm?.call(tableBpm);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Set App BPM → ${tableBpm.toStringAsFixed(1)}',
                                  ),
                                ),
                              );
                            },
                      child: const Text('Set App BPM'),
                    ),
                    const SizedBox(height: 12),
                    _DebugLine(label: 'chunks', value: '$_chunks'),
                    _DebugLine(
                      label: 'last chunk bytes',
                      value: '$_lastChunkBytes',
                    ),
                    _DebugLine(label: 'env_len', value: '$envLen'),
                    _DebugLine(
                      label: 'energy_db',
                      value: energyDb.isNaN
                          ? 'nan'
                          : '${energyDb.toStringAsFixed(1)} dB',
                    ),
                    _DebugLine(label: 'format', value: '$fmt'),
                    _DebugLine(
                      label: 'frame RMS',
                      value:
                          frameRms.isNaN ? 'nan' : frameRms.toStringAsFixed(6),
                    ),
                    const SizedBox(height: 12),
                    if (tableBpm != null) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton(
                            onPressed: _copyDelayTable,
                            child: const Text('Copy Table'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: _saveDelayTableTxt,
                            child: const Text('Save .txt'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ListView(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: delayTableForBpm(tableBpm).map((r) {
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(r.label),
                              Text('${r.ms.toStringAsFixed(1)} ms'),
                            ],
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DebugLine extends StatelessWidget {
  final String label;
  final String value;
  const _DebugLine({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        '$label: $value',
        softWrap: true,
        overflow: TextOverflow.fade,
        maxLines: 2,
      ),
    );
  }
}

class TapIntent extends Intent {
  const TapIntent();
}

class TapTempoPanel extends StatefulWidget {
  const TapTempoPanel({super.key, required this.onBpmChanged});
  final void Function(double? bpm) onBpmChanged;
  @override
  State<TapTempoPanel> createState() => _TapTempoPanelState();
}

class _TapTempoPanelState extends State<TapTempoPanel> {
  final List<int> _tapsMs = [];
  double? _bpmSmoothed;
  double _confidence = 0.0;

  static const int _maxTaps = 12;
  static const int _resetGapMs = 2000;
  static const double _minBpm = 40.0;
  static const double _maxBpm = 240.0;
  static const double _emaAlpha = 0.35;

  void _handleTap() {
    HapticFeedback.lightImpact();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_tapsMs.isNotEmpty && (now - _tapsMs.last) > _resetGapMs) {
      _tapsMs.clear();
      _bpmSmoothed = null;
      _confidence = 0;
    }
    _tapsMs.add(now);
    if (_tapsMs.length > _maxTaps) _tapsMs.removeAt(0);
    _recompute();
  }

  void _reset() {
    _tapsMs.clear();
    _bpmSmoothed = null;
    _confidence = 0;
    widget.onBpmChanged(null);
    setState(() {});
  }

  void _nudge(double delta) {
    if (_bpmSmoothed == null) return;
    final v = (_bpmSmoothed! + delta).clamp(_minBpm, _maxBpm);
    _bpmSmoothed = v;
    widget.onBpmChanged(v);
    setState(() {});
  }

  void _mult(double factor) {
    if (_bpmSmoothed == null) return;
    double v = _bpmSmoothed! * factor;
    while (v < _minBpm) {
      v *= 2;
    }
    while (v > _maxBpm) {
      v /= 2;
    }
    _bpmSmoothed = v;
    widget.onBpmChanged(v);
    setState(() {});
  }

  void _recompute() {
    if (_tapsMs.length < 3) {
      widget.onBpmChanged(null);
      setState(() => _confidence = 0);
      return;
    }

    final iois = <double>[];
    for (int i = 1; i < _tapsMs.length; i++) {
      iois.add((_tapsMs[i] - _tapsMs[i - 1]).toDouble());
    }

    final sorted = List<double>.from(iois)..sort();
    final q1 = _percentile(sorted, 0.25);
    final q3 = _percentile(sorted, 0.75);
    final iqr = q3 - q1;
    final lo = q1 - 1.5 * iqr;
    final hi = q3 + 1.5 * iqr;
    final kept = <double>[];
    for (final v in iois) {
      if (v >= lo && v <= hi) kept.add(v);
    }
    if (kept.isEmpty) {
      widget.onBpmChanged(null);
      setState(() => _confidence = 0);
      return;
    }

    kept.sort();
    final medianIoiMs = kept.length.isOdd
        ? kept[kept.length ~/ 2]
        : 0.5 * (kept[kept.length ~/ 2 - 1] + kept[kept.length ~/ 2]);
    double bpm = 60000.0 / medianIoiMs;
    while (bpm < _minBpm) {
      bpm *= 2;
    }
    while (bpm > _maxBpm) {
      bpm /= 2;
    }

    final mean = kept.reduce((a, b) => a + b) / kept.length;
    double varSum = 0.0;
    for (final v in kept) {
      final d = v - mean;
      varSum += d * d;
    }
    final std = kept.length > 1 ? math.sqrt(varSum / (kept.length - 1)) : 0.0;
    final cv = mean > 0 ? std / mean : 1.0;
    _confidence = (1.0 - cv * 2.0).clamp(0.0, 1.0);

    _bpmSmoothed = (_bpmSmoothed == null)
        ? bpm
        : (_emaAlpha * bpm + (1 - _emaAlpha) * _bpmSmoothed!);

    widget.onBpmChanged(_bpmSmoothed);
    setState(() {});
  }

  double _percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0;
    final r = p * (sorted.length - 1);
    final lo = r.floor();
    final hi = r.ceil();
    if (lo == hi) return sorted[lo];
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (r - lo);
  }

  @override
  Widget build(BuildContext context) {
    final bpmText = _bpmSmoothed == null
        ? 'Tap to measure BPM'
        : '${_bpmSmoothed!.toStringAsFixed(1)} BPM';
    final confPct = (_confidence * 100).round();

    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.space): const TapIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          TapIntent: CallbackAction<TapIntent>(
            onInvoke: (intent) {
              _handleTap();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Card(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Text(
                    bpmText,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 220,
                        child: ElevatedButton(
                          onPressed: _handleTap,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                          ),
                          child: const Text('TAP (Space)'),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: _reset,
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    runAlignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Wrap(
                        spacing: 6,
                        children: [
                          _NudgeBtn(label: '−5', onTap: () => _nudge(-5)),
                          _NudgeBtn(label: '−1', onTap: () => _nudge(-1)),
                          _NudgeBtn(label: '+1', onTap: () => _nudge(1)),
                          _NudgeBtn(label: '+5', onTap: () => _nudge(5)),
                        ],
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          _NudgeBtn(label: '÷2', onTap: () => _mult(0.5)),
                          _NudgeBtn(label: '×2', onTap: () => _mult(2.0)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Stability'),
                      const SizedBox(width: 8),
                      Expanded(
                        child: LinearProgressIndicator(value: _confidence),
                      ),
                      const SizedBox(width: 8),
                      Text('$confPct%'),
                    ],
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

class _NudgeBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _NudgeBtn({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return OutlinedButton(onPressed: onTap, child: Text(label));
  }
}
