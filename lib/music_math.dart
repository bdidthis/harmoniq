// lib/music_math.dart
// Single source of truth for all music math utilities

class DelayRow {
  final String label;
  final double ms;
  const DelayRow(this.label, this.ms);
}

class MMCell {
  final double ms;
  final double hz;
  const MMCell({required this.ms, required this.hz});
}

class MMRow {
  final String label;
  final MMCell notes;
  final MMCell triplets;
  final MMCell dotted;

  const MMRow({
    required this.label,
    required this.notes,
    required this.triplets,
    required this.dotted,
  });
}

class MusicMathRows {
  static List<MMRow> buildThreeColumn(double bpm) {
    if (bpm <= 0 || !bpm.isFinite) return [];

    final rows = <MMRow>[];

    MMCell cell(double ms) {
      final hz = ms > 0 ? 1000.0 / ms : 0.0;
      return MMCell(ms: ms, hz: hz);
    }

    // Labels you want visible in the UI
    final divisions = [
      (label: 'Whole', beats: 4.0),
      (label: 'Half', beats: 2.0),
      (label: 'Quarter', beats: 1.0),
      (label: 'Eighth', beats: 0.5),
      (label: '16th', beats: 0.25),
      (label: '32nd', beats: 0.125),
      (label: '64th', beats: 0.0625),
    ];

    for (final div in divisions) {
      final baseMs = MusicMath.msForBeats(bpm, div.beats);
      rows.add(
        MMRow(
          label: div.label,
          notes: cell(baseMs),
          triplets: cell(baseMs * (2.0 / 3.0)),
          dotted: cell(baseMs * 1.5),
        ),
      );
    }

    return rows;
  }
}

class ScaleNotes {
  static const _noteNames = [
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

  static List<String> major(String root) {
    final rootIndex = _getRootIndex(root);
    if (rootIndex == -1) return [];
    const intervals = [0, 2, 4, 5, 7, 9, 11];
    return intervals.map((i) => _noteNames[(rootIndex + i) % 12]).toList();
  }

  static List<String> naturalMinor(String root) {
    final rootIndex = _getRootIndex(root);
    if (rootIndex == -1) return [];
    const intervals = [0, 2, 3, 5, 7, 8, 10];
    return intervals.map((i) => _noteNames[(rootIndex + i) % 12]).toList();
  }

  static int _getRootIndex(String root) {
    final normalized = root.replaceAll('♭', 'b').replaceAll('♯', '#');
    const flatMap = {
      'Db': 'C#',
      'Eb': 'D#',
      'Gb': 'F#',
      'Ab': 'G#',
      'Bb': 'A#',
    };
    final sharp = flatMap[normalized] ?? normalized;
    return _noteNames.indexOf(sharp);
  }
}

class MusicMath {
  /// Milliseconds for N beats at BPM.
  static double msForBeats(double bpm, double beats) {
    if (!bpm.isFinite || bpm <= 0) return 0.0;
    return (beats * 60000.0) / bpm;
  }

  /// Milliseconds for a fractional note (1/1, 1/2, 1/4, etc.)
  /// Uses 4/4 as reference: whole = 4 beats.
  static double msForFraction(double bpm, int numerator, int denominator) {
    if (!bpm.isFinite || bpm <= 0 || denominator == 0) return 0.0;
    final double beats = 4.0 * numerator / denominator;
    return msForBeats(bpm, beats);
  }

  /// Dotted note = 1.5x base value.
  static double msForDotted(double bpm, int numerator, int denominator) {
    return msForFraction(bpm, numerator, denominator) * 1.5;
  }

  /// Triplet note = 2/3 of base value.
  static double msForTriplet(double bpm, int numerator, int denominator) {
    return msForFraction(bpm, numerator, denominator) * (2.0 / 3.0);
  }
}

/// Legacy function for backwards compatibility.
List<DelayRow> buildDelayTable(double bpm) {
  final entries = <(String, double)>[
    ('1/1', MusicMath.msForFraction(bpm, 1, 1)),
    ('1/2', MusicMath.msForFraction(bpm, 1, 2)),
    ('1/4', MusicMath.msForFraction(bpm, 1, 4)),
    ('1/8', MusicMath.msForFraction(bpm, 1, 8)),
    ('1/16', MusicMath.msForFraction(bpm, 1, 16)),
    ('1/32', MusicMath.msForFraction(bpm, 1, 32)),
    ('1/4 dotted', MusicMath.msForDotted(bpm, 1, 4)),
    ('1/8 dotted', MusicMath.msForDotted(bpm, 1, 8)),
    ('1/16 dotted', MusicMath.msForDotted(bpm, 1, 16)),
    ('1/4 triplet', MusicMath.msForTriplet(bpm, 1, 4)),
    ('1/8 triplet', MusicMath.msForTriplet(bpm, 1, 8)),
    ('1/16 triplet', MusicMath.msForTriplet(bpm, 1, 16)),
  ];
  return entries.map((e) => DelayRow(e.$1, e.$2)).toList(growable: false);
}

/// Modern alias.
List<DelayRow> delayTableForBpm(double bpm) => buildDelayTable(bpm);
