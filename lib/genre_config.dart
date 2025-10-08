// lib/genre_config.dart
// Day-7 safe config: keep your full API & JSON overrides,
// but route all defaults/subgenres to key_small.tflite (only real model on disk).

import 'dart:convert';
import 'package:flutter/services.dart';

enum Genre {
  electronic,
  rock,
  jazz,
  classical,
  hiphop,
  rnb,
  pop,
  country,
  latin,
  world,
  auto,
}

enum Subgenre {
  // Electronic
  house,
  techno,
  trance,
  dubstep,
  drumnbass,
  trap,
  future,
  ambient,
  // Rock
  classic,
  alternative,
  metal,
  punk,
  indie,
  // Jazz
  bebop,
  swing,
  fusion,
  smooth,
  // Classical
  baroque,
  romantic,
  modern,
  // Hip-Hop
  oldschool,
  newschool,
  lofi,
  // R&B
  contemporary,
  soul,
  funk,
  // Pop
  mainstream,
  synthpop,
  kpop,
  // Country
  traditional,
  modernCountry,
  // Latin
  salsa,
  reggaeton,
  bossa,
  // World
  african,
  asian,
  middle_eastern,
  // Default
  none,
}

enum TemporalSmoothing { none, ema, hmm, dbn }

class GenreModelConfig {
  final String modelPath;
  final String fallbackPath;
  final bool useClassical;
  final double classicalWeight;
  final double whiteningAlpha;
  final double bassSuppression;
  final int hpcpBins;
  final TemporalSmoothing smoothingType;
  final double smoothingStrength;
  final bool supportsTuningRegression;
  final double minConfidence;
  final int lockFrames;
  final Map<String, dynamic> customParams;

  const GenreModelConfig({
    required this.modelPath,
    this.fallbackPath = 'assets/models/key_small.tflite',
    this.useClassical = true,
    this.classicalWeight = 0.35,
    this.whiteningAlpha = 0.08,
    this.bassSuppression = 85.0,
    this.hpcpBins =
        12, // 12 works everywhere; switch to 36/48 when your models require it
    this.smoothingType = TemporalSmoothing.ema,
    this.smoothingStrength = 0.80,
    this.supportsTuningRegression = false,
    this.minConfidence = 0.05,
    this.lockFrames = 6,
    this.customParams = const {},
  });

  factory GenreModelConfig.fromJson(Map<String, dynamic> json) {
    return GenreModelConfig(
      modelPath: json['modelPath'] ?? 'assets/models/key_small.tflite',
      fallbackPath: json['fallbackPath'] ?? 'assets/models/key_small.tflite',
      useClassical: json['useClassical'] ?? true,
      classicalWeight: (json['classicalWeight'] ?? 0.35).toDouble(),
      whiteningAlpha: (json['whiteningAlpha'] ?? 0.08).toDouble(),
      bassSuppression: (json['bassSuppression'] ?? 85.0).toDouble(),
      hpcpBins: (json['hpcpBins'] ?? 12),
      smoothingType: TemporalSmoothing.values.firstWhere(
        (e) => e.name == json['smoothingType'],
        orElse: () => TemporalSmoothing.ema,
      ),
      smoothingStrength: (json['smoothingStrength'] ?? 0.80).toDouble(),
      supportsTuningRegression: json['supportsTuningRegression'] ?? false,
      minConfidence: (json['minConfidence'] ?? 0.05).toDouble(),
      lockFrames: json['lockFrames'] ?? 6,
      customParams: (json['customParams'] ?? {}) as Map<String, dynamic>,
    );
  }

  Map<String, dynamic> toJson() => {
        'modelPath': modelPath,
        'fallbackPath': fallbackPath,
        'useClassical': useClassical,
        'classicalWeight': classicalWeight,
        'whiteningAlpha': whiteningAlpha,
        'bassSuppression': bassSuppression,
        'hpcpBins': hpcpBins,
        'smoothingType': smoothingType.name,
        'smoothingStrength': smoothingStrength,
        'supportsTuningRegression': supportsTuningRegression,
        'minConfidence': minConfidence,
        'lockFrames': lockFrames,
        'customParams': customParams,
      };
}

class GenreConfigManager {
  static final GenreConfigManager _instance = GenreConfigManager._internal();
  factory GenreConfigManager() => _instance;
  GenreConfigManager._internal();

  final Map<Genre, Map<Subgenre, GenreModelConfig>> _configs = {};
  bool _initialized = false;

  static const String _small = 'assets/models/key_small.tflite';

  // Updated defaults → ALL routed to the one known-good model
  static final Map<Genre, GenreModelConfig> _defaultConfigs = {
    Genre.electronic: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.08,
      bassSuppression: 75.0,
      hpcpBins: 12,
      smoothingType: TemporalSmoothing.ema,
      smoothingStrength: 0.82,
      classicalWeight: 0.30,
      customParams: const {'use_hpss': true},
    ),
    Genre.rock: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.06,
      bassSuppression: 90.0,
      smoothingStrength: 0.78,
      classicalWeight: 0.40,
    ),
    Genre.jazz: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.05,
      bassSuppression: 90.0,
      smoothingType: TemporalSmoothing.dbn,
      smoothingStrength: 0.80,
      classicalWeight: 0.45,
    ),
    Genre.classical: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.04,
      bassSuppression: 95.0,
      smoothingType: TemporalSmoothing.dbn,
      smoothingStrength: 0.85,
      classicalWeight: 0.55,
    ),
    Genre.hiphop: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.10,
      bassSuppression: 70.0,
      smoothingType: TemporalSmoothing.hmm,
      smoothingStrength: 0.85,
      classicalWeight: 0.40,
      customParams: const {'use_hpss': true},
    ),
    Genre.rnb: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.06,
      bassSuppression: 85.0,
      smoothingStrength: 0.80,
      classicalWeight: 0.35,
    ),
    Genre.pop: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.06,
      bassSuppression: 85.0,
      smoothingStrength: 0.80,
      classicalWeight: 0.35,
    ),
    Genre.country: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.05,
      bassSuppression: 90.0,
      smoothingStrength: 0.78,
      classicalWeight: 0.40,
    ),
    Genre.latin: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.06,
      bassSuppression: 80.0,
      smoothingStrength: 0.80,
      classicalWeight: 0.35,
    ),
    Genre.world: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.05,
      bassSuppression: 85.0,
      smoothingStrength: 0.80,
      classicalWeight: 0.35,
    ),
    Genre.auto: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.06,
      bassSuppression: 85.0,
      smoothingStrength: 0.80,
      classicalWeight: 0.35,
    ),
  };

  // Subgenre overrides → still point to the small model
  static final Map<Subgenre, GenreModelConfig> _subgenreConfigs = {
    // Electronic
    Subgenre.house: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.08,
      bassSuppression: 80.0,
      smoothingStrength: 0.82,
      classicalWeight: 0.25,
      customParams: const {'use_hpss': true},
    ),
    Subgenre.techno: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.08,
      bassSuppression: 80.0,
      smoothingStrength: 0.84,
      classicalWeight: 0.20,
      customParams: const {'use_hpss': true},
    ),
    Subgenre.trance: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.08,
      bassSuppression: 75.0,
      smoothingStrength: 0.86,
      classicalWeight: 0.25,
      customParams: const {'use_hpss': true},
    ),
    Subgenre.dubstep: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.10,
      bassSuppression: 65.0,
      smoothingStrength: 0.84,
      classicalWeight: 0.30,
      customParams: const {'use_hpss': true},
    ),
    Subgenre.drumnbass: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.08,
      bassSuppression: 70.0,
      smoothingStrength: 0.84,
      classicalWeight: 0.25,
      customParams: const {'use_hpss': true},
    ),
    // Hip-Hop
    Subgenre.trap: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.10,
      bassSuppression: 70.0,
      smoothingType: TemporalSmoothing.hmm,
      smoothingStrength: 0.86,
      classicalWeight: 0.35,
      customParams: const {'use_hpss': true},
    ),
    // Jazz
    Subgenre.bebop: GenreModelConfig(
      modelPath: _small,
      whiteningAlpha: 0.05,
      bassSuppression: 95.0,
      smoothingType: TemporalSmoothing.dbn,
      smoothingStrength: 0.84,
      classicalWeight: 0.50,
    ),
  };

  Future<void> initialize() async {
    if (_initialized) return;

    for (final genre in Genre.values) {
      _configs[genre] = {};
    }

    _defaultConfigs.forEach((genre, config) {
      _configs[genre]![Subgenre.none] = config;
    });

    _subgenreConfigs.forEach((subgenre, config) {
      final genre = _getGenreForSubgenre(subgenre);
      if (genre != null) {
        _configs[genre]![subgenre] = config;
      }
    });

    // Optional external overrides file can still replace any of the above.
    try {
      final jsonString =
          await rootBundle.loadString('assets/config/genre_models.json');
      final jsonData = json.decode(jsonString) as Map<String, dynamic>;
      _loadCustomConfigs(jsonData);
    } catch (_) {
      // No overrides present; ignore.
    }

    _initialized = true;
  }

  void _loadCustomConfigs(Map<String, dynamic> data) {
    data.forEach((genreStr, genreData) {
      try {
        final genre = Genre.values.firstWhere((g) => g.name == genreStr);
        if (genreData is Map<String, dynamic>) {
          genreData.forEach((subgenreStr, configData) {
            try {
              final subgenre =
                  Subgenre.values.firstWhere((s) => s.name == subgenreStr);
              if (configData is Map<String, dynamic>) {
                _configs[genre]![subgenre] =
                    GenreModelConfig.fromJson(configData);
              }
            } catch (_) {}
          });
        }
      } catch (_) {}
    });
  }

  GenreModelConfig getConfig({
    Genre genre = Genre.auto,
    Subgenre subgenre = Subgenre.none,
  }) {
    if (!_initialized) {
      // Safe default if called early
      return const GenreModelConfig(modelPath: _small);
    }

    if (genre == Genre.auto) {
      genre = _autoDetectGenre();
    }

    if (subgenre != Subgenre.none) {
      final subConfig = _configs[genre]?[subgenre];
      if (subConfig != null) return subConfig;
    }

    final genreConfig =
        _configs[genre]?[Subgenre.none] ?? _defaultConfigs[genre];
    if (genreConfig != null) return genreConfig;

    return const GenreModelConfig(modelPath: _small);
  }

  Genre? _getGenreForSubgenre(Subgenre subgenre) {
    switch (subgenre) {
      case Subgenre.house:
      case Subgenre.techno:
      case Subgenre.trance:
      case Subgenre.dubstep:
      case Subgenre.drumnbass:
      case Subgenre.trap:
      case Subgenre.future:
      case Subgenre.ambient:
        return Genre.electronic;
      case Subgenre.classic:
      case Subgenre.alternative:
      case Subgenre.metal:
      case Subgenre.punk:
      case Subgenre.indie:
        return Genre.rock;
      case Subgenre.bebop:
      case Subgenre.swing:
      case Subgenre.fusion:
      case Subgenre.smooth:
        return Genre.jazz;
      case Subgenre.baroque:
      case Subgenre.romantic:
      case Subgenre.modern:
        return Genre.classical;
      case Subgenre.oldschool:
      case Subgenre.newschool:
      case Subgenre.lofi:
        return Genre.hiphop;
      case Subgenre.contemporary:
      case Subgenre.soul:
      case Subgenre.funk:
        return Genre.rnb;
      case Subgenre.mainstream:
      case Subgenre.synthpop:
      case Subgenre.kpop:
        return Genre.pop;
      case Subgenre.traditional:
      case Subgenre.modernCountry:
        return Genre.country;
      case Subgenre.salsa:
      case Subgenre.reggaeton:
      case Subgenre.bossa:
        return Genre.latin;
      case Subgenre.african:
      case Subgenre.asian:
      case Subgenre.middle_eastern:
        return Genre.world;
      default:
        return null;
    }
  }

  Genre _autoDetectGenre() {
    // Simple default for now
    return Genre.pop;
  }

  List<String> getAvailableModels() {
    final models = <String>{};
    for (var genreMap in _configs.values) {
      for (var config in genreMap.values) {
        models.add(config.modelPath);
      }
    }
    return models.toList()..sort();
  }
}
