import 'package:flutter/material.dart';
import 'metrics_bus.dart';

class DebugMetricsPage extends StatelessWidget {
  const DebugMetricsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final bus = MetricsBus.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Debug · Metrics')),
      body: AnimatedBuilder(
        animation: bus,
        builder: (_, __) {
          final s = bus.last;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _row(
                'BPM',
                s.bpm != null && s.bpm! > 0 ? s.bpm!.toStringAsFixed(1) : '--',
              ),
              _row('Locked', s.locked ? 'yes' : 'no'),
              _row('Stability', '${(s.stability * 100).toStringAsFixed(0)}%'),
              const SizedBox(height: 12),
              _row('Key', s.key),
              _row(
                'Key Confidence',
                '${(s.keyConf * 100).toStringAsFixed(1)}%',
              ),
              _row(
                'Alternates',
                s.alternates.isEmpty ? '--' : s.alternates.join(', '),
              ),
              const SizedBox(height: 12),
              _row('Beat-sync Key', s.beatKey ?? '--'),
              _row(
                'Beat-sync Conf',
                s.beatConf != null
                    ? '${(s.beatConf! * 100).toStringAsFixed(1)}%'
                    : '--',
              ),
              const SizedBox(height: 12),
              _row('Learned Key', s.mlKey ?? '--'),
              _row(
                'Learned Conf',
                s.mlConf != null
                    ? '${(s.mlConf! * 100).toStringAsFixed(1)}%'
                    : '--',
              ),
              const SizedBox(height: 12),
              _row(
                'Tuning',
                s.tuningCents != null
                    ? (s.tuningCents! >= 0
                        ? '+${s.tuningCents!.toStringAsFixed(1)}¢'
                        : '${s.tuningCents!.toStringAsFixed(1)}¢')
                    : '--',
              ),
              _row(
                'Pitch Hz',
                s.pitchHz != null && s.pitchHz! > 0
                    ? s.pitchHz!.toStringAsFixed(1)
                    : '--',
              ),
              _row('Pitch Note', s.pitchNote ?? '--'),
              _row(
                'Pitch Cents',
                s.pitchCents != null
                    ? (s.pitchCents! >= 0
                        ? '+${s.pitchCents!.toStringAsFixed(1)}¢'
                        : '${s.pitchCents!.toStringAsFixed(1)}¢')
                    : '--',
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(String a, String b) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(a, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(b)),
        ],
      ),
    );
  }
}
