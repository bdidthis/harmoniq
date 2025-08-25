class DelayRow {
  final String label;
  final double ms;
  DelayRow(this.label, this.ms);
}

double msPerBeat(double bpm) => 60000.0 / bpm;

List<DelayRow> delayTableForBpm(double bpm) {
  final beat = msPerBeat(bpm);
  double n(double beats) => beats * beat;
  final base = <String, double>{
    "1/1": 4.0,
    "1/2": 2.0,
    "1/4": 1.0,
    "1/8": 0.5,
    "1/16": 0.25,
    "1/32": 0.125,
  };
  final rows = <DelayRow>[];
  base.forEach((k, beats) {
    rows.add(DelayRow(k, n(beats)));
    rows.add(DelayRow("$k dot", n(beats * 1.5)));
    rows.add(DelayRow("$k T", n(beats * (2.0 / 3.0))));
  });
  return rows;
}

({int bar, int beat, double beatFrac}) timeToBars(
  double seconds, {
  required double bpm,
  int beatsPerBar = 4,
}) {
  final beats = seconds * bpm / 60.0;
  final bar = (beats / beatsPerBar).floor() + 1;
  final beat = (beats % beatsPerBar).floor() + 1;
  final beatFrac = beats - beats.floorToDouble();
  return (bar: bar, beat: beat, beatFrac: beatFrac);
}

