import 'package:flutter/foundation.dart';

class MetricsSnapshot {
  final double? bpm;
  final bool locked;
  final double stability;
  final String key;
  final double keyConf;
  final List<String> alternates;
  final double? tuningCents;
  final double? pitchHz;
  final String? pitchNote;
  final double? pitchCents;
  final String? mlKey;
  final double? mlConf;
  final String? beatKey;
  final double? beatConf;
  const MetricsSnapshot({
    required this.bpm,
    required this.locked,
    required this.stability,
    required this.key,
    required this.keyConf,
    required this.alternates,
    this.tuningCents,
    this.pitchHz,
    this.pitchNote,
    this.pitchCents,
    this.mlKey,
    this.mlConf,
    this.beatKey,
    this.beatConf,
  });
  static const empty = MetricsSnapshot(
    bpm: null,
    locked: false,
    stability: 0.0,
    key: '--',
    keyConf: 0.0,
    alternates: [],
  );
}

class MetricsBus extends ChangeNotifier {
  MetricsSnapshot _last = MetricsSnapshot.empty;
  static final MetricsBus instance = MetricsBus._();
  MetricsBus._();
  MetricsSnapshot get last => _last;
  void update(MetricsSnapshot s) {
    _last = s;
    notifyListeners();
  }
}
