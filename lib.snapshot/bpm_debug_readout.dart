// lib/widgets/bpm_debug_readout.dart
import 'package:flutter/material.dart';
import '../bpm_estimator.dart';

class BpmDebugReadout extends StatelessWidget {
  final BpmEstimator estimator;
  const BpmDebugReadout({super.key, required this.estimator});

  @override
  Widget build(BuildContext context) {
    final stats = estimator.debugStats;
    final bpmStr = estimator.bpm?.toStringAsFixed(1) ?? "--";
    final envLen = stats['env_len'];
    final energyDb =
        (stats['energy_db'] as double?)?.toStringAsFixed(1) ?? "nan";
    final fmt = stats['format_guess'];
    final rms =
        (stats['last_frame_rms'] as double?)?.toStringAsFixed(6) ?? "nan";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("BPM: $bpmStr", style: const TextStyle(fontSize: 24)),
        Text("env_len: $envLen"),
        Text("energy_db: $energyDb dB"),
        Text("format: $fmt  |  frame RMS: $rms"),
      ],
    );
  }
}
