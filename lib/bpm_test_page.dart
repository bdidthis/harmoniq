import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'bpm_estimator.dart';
import 'music_math.dart';

class BpmTestPage extends StatefulWidget {
  const BpmTestPage({super.key});
  @override
  State<BpmTestPage> createState() => _BpmTestPageState();
}

class _BpmTestPageState extends State<BpmTestPage> {
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;

  static const int _sampleRate = 48000;
  static const int _channels = 1;

  final _bpm = BpmEstimator(sampleRate: _sampleRate);
  double? _bpmNow;
  double _rms = 0.0;
  bool _on = false;

  Future<void> _start() async {
    final ok = await _rec.hasPermission();
    if (!ok) return;
    final cfg = const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _sampleRate,
      numChannels: _channels,
    );
    final stream = await _rec.startStream(cfg);
    await _sub?.cancel();
    _sub = stream.listen(_onBytes, onError: (_) {});
    setState(() => _on = true);
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    await _rec.stop();
    setState(() {
      _on = false;
      _rms = 0.0;
      _bpmNow = null;
    });
  }

  void _onBytes(Uint8List bytes) {
    double rms = 0.0;
    bool useFloat = false;

    if (bytes.isNotEmpty) {
      if (bytes.lengthInBytes % 2 == 0) {
        final i16 = bytes.buffer
            .asInt16List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
        double sum = 0.0;
        for (int i = 0; i < i16.length; i++) {
          final s = i16[i] / 32768.0;
          sum += s * s;
        }
        rms = i16.isEmpty ? 0.0 : (sum / i16.length);
        if (rms < 1e-8 && bytes.lengthInBytes % 4 == 0) {
          useFloat = true;
        }
      } else if (bytes.lengthInBytes % 4 == 0) {
        useFloat = true;
      }

      if (useFloat) {
        final f32 = bytes.buffer
            .asFloat32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
        double sum = 0.0;
        for (int i = 0; i < f32.length; i++) {
          final s = f32[i];
          sum += s * s;
        }
        rms = f32.isEmpty ? 0.0 : (sum / f32.length);
        _bpm.addBytes(bytes, channels: _channels, isFloat32: true);
      } else {
        _bpm.addBytes(bytes, channels: _channels, isFloat32: false);
      }
    }

    final val = _bpm.bpm;

    if (!mounted) return;
    setState(() {
      _rms = rms.clamp(0.0, 1.0);
      if (val != null) _bpmNow = val;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _rec.stop();
    _rec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final level = _rms.isNaN ? 0.0 : _rms.clamp(0.0, 1.0);
    return Scaffold(
      appBar: AppBar(title: const Text('BPM Test')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ElevatedButton(
                onPressed: _on ? _stop : _start,
                child: Text(_on ? 'Stop' : 'Start')),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: level),
            const SizedBox(height: 12),
            Text(
              _bpmNow == null ? '— BPM' : '${_bpmNow!.toStringAsFixed(1)} BPM',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (_bpmNow != null)
              Expanded(
                child: ListView(
                  children: delayTableForBpm(_bpmNow!).map((r) {
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(r.label),
                        Text('${r.ms.toStringAsFixed(1)} ms'),
                      ],
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
