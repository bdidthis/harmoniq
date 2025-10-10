// lib/key_model.dart
// Fixed: Improved error handling and initialization

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';

enum ModelMode { classical, learned, hybrid }

class KeyModelResult {
  final String label;
  final double confidence;
  final List<double> probs;
  KeyModelResult(this.label, this.confidence, this.probs);
}

class LearnedKeyModel {
  final String assetPath;
  final double temperature;
  Interpreter? _interpreter;
  bool _isLoading = false;

  final List<String> _labels = List<String>.generate(24, (i) {
    const pcs = [
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
    final r = i ~/ 2;
    final isMaj = (i % 2) == 0;
    return '${pcs[r]} ${isMaj ? 'major' : 'minor'}';
  });

  LearnedKeyModel({
    this.assetPath = 'assets/models/key_small.tflite',
    this.temperature = 1.0,
  });

  Future<bool> load() async {
    if (_isLoading) return false;
    _isLoading = true;

    try {
      _interpreter = await Interpreter.fromAsset(assetPath);
      _isLoading = false;
      return true;
    } catch (e) {
      print('Failed to load model from $assetPath: $e');
      _interpreter = null;
      _isLoading = false;
      return false;
    }
  }

  bool get isReady => _interpreter != null && !_isLoading;

  KeyModelResult inferFromChroma(List<double> chroma12) {
    if (!isReady || chroma12.length != 12) {
      return KeyModelResult('--', 0.0, List<double>.filled(24, 0.0));
    }

    try {
      final input = Float32List.fromList(List<double>.from(chroma12));
      final inputBuffer = input.reshape([1, 12]);
      final output = List.filled(1, List.filled(24, 0.0));
      _interpreter!.run(inputBuffer, output);

      final raw = List<double>.from(
        output[0].map((e) => e is double ? e : (e as num).toDouble()),
      );
      final probs = _softmax(raw, temperature);

      int best = 0;
      double bestP = probs[0];
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > bestP) {
          bestP = probs[i];
          best = i;
        }
      }

      return KeyModelResult(
        best < _labels.length ? _labels[best] : '--',
        bestP,
        probs,
      );
    } catch (e) {
      print('Inference error: $e');
      return KeyModelResult('--', 0.0, List<double>.filled(24, 0.0));
    }
  }

  List<double> _softmax(List<double> x, double temp) {
    final t = temp <= 0 ? 1.0 : temp;
    double maxV = -1e9;
    for (final v in x) {
      if (v.isFinite && v > maxV) maxV = v;
    }

    final List<double> e = List<double>.filled(x.length, 0.0);
    double sum = 0.0;
    for (int i = 0; i < x.length; i++) {
      if (x[i].isFinite) {
        e[i] = math.exp((x[i] - maxV) / t);
        sum += e[i];
      }
    }

    if (sum <= 0) {
      // Return uniform distribution if something went wrong
      final uniform = 1.0 / x.length;
      return List<double>.filled(x.length, uniform);
    }

    for (int i = 0; i < e.length; i++) {
      e[i] /= sum;
    }
    return e;
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}
