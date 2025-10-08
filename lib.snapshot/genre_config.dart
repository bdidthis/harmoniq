// lib/genre_config.dart
// Genre-specific model configuration and mapping system

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
    this.fallbackPath = 'assets/models/key_default.tflite',
    this.useClassical = true,
    this.classicalWeight = 0.3,
    this.whiteningAlpha = 0.7,
    this.bassSuppression = 120.0,
    this.hpcpBins = 36,
    this.smoothingType = TemporalSmoothing.hmm,
    this.smoothingStrength = 0.5,
    this.supportsTuningRegression = false,
    this.minConfidence = 0.6,
    this.lockFrames = 3,
    this.customParams = const {},
  });

  factory GenreModelConfig.fromJson(Map<String, dynamic> json) {
    return GenreModelConfig(
      modelPath: json['modelPath'] ?? 'assets/models/key_default.tflite',
      fallbackPath: json['fallbackPath'] ?? 'assets/models/key_default.tflite',
      useClassical: json['useClassical'] ?? true,
      classicalWeight: (json['classicalWeight'] ?? 0.3).toDouble(),
      whiteningAlpha: (json['whiteningAlpha'] ?? 0.7).toDouble(),
      bassSuppression: (json['bassSuppression'] ?? 120.0).toDouble(),
      hpcpBins: json['hpcpBins'] ?? 36,
      smoothingType: TemporalSmoothing.values.firstWhere(
        (e) => e.name == json['smoothingType'],
        orElse: () => TemporalSmoothing.hmm,
      ),
      smoothingStrength: (json['smoothingStrength'] ?? 0.5).toDouble(),
      supportsTuningRegression: json['supportsTuningRegression'] ?? false,
      minConfidence: (json['minConfidence'] ?? 0.6).toDouble(),
      lockFrames: json['lockFrames'] ?? 3,
      customParams: json['customParams'] ?? {},
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

  // Default configurations per genre
  static const Map<Genre, GenreModelConfig> _defaultConfigs = {
    Genre.electronic: GenreModelConfig(
      modelPath: 'assets/models/key_electronic.tflite',
      whiteningAlpha: 0.8,
      bassSuppression: 100.0,
      hpcpBins: 48,
      smoothingType: TemporalSmoothing.hmm,
      smoothingStrength: 0.6,
      supportsTuningRegression: true,
    ),
    Genre.rock: GenreModelConfig(
      modelPath: 'assets/models/key_rock.tflite',
      whiteningAlpha: 0.6,
      bassSuppression: 150.0,
      hpcpBins: 36,
      smoothingType: TemporalSmoothing.ema,
      smoothingStrength: 0.4,
    ),
    Genre.jazz: GenreModelConfig(
      modelPath: 'assets/models/key_jazz.tflite',
      whiteningAlpha: 0.5,
      bassSuppression: 80.0,
      hpcpBins: 60,
      smoothingType: TemporalSmoothing.dbn,
      smoothingStrength: 0.7,
      classicalWeight: 0.4,
    ),
    Genre.classical: GenreModelConfig(
      modelPath: 'assets/models/key_classical.tflite',
      useClassical: true,
      classicalWeight: 0.5,
      whiteningAlpha: 0.3,
      bassSuppression: 60.0,
      hpcpBins: 72,
      smoothingType: TemporalSmoothing.dbn,
      smoothingStrength: 0.8,
    ),
    Genre.hiphop: GenreModelConfig(
      modelPath: 'assets/models/key_hiphop.tflite',
      whiteningAlpha: 0.9,
      bassSuppression: 200.0,
      hpcpBins: 36,
      smoothingType: TemporalSmoothing.hmm,
      smoothingStrength: 0.5,
      supportsTuningRegression: true,
    ),
    Genre.rnb: GenreModelConfig(
      modelPath: 'assets/models/key_rnb.tflite',
      whiteningAlpha: 0.7,
      bassSuppression: 120.0,
      hpcpBins: 48,
      smoothingType: TemporalSmoothing.hmm,
      smoothingStrength: 0.6,
    ),
    Genre.pop: GenreModelConfig(
      modelPath: 'assets/models/key_pop.tflite',
      whiteningAlpha: 0.6,
      bassSuppression: 100.0,
      hpcpBins: 36,
      smoothingType: TemporalSmoothing.ema,
      smoothingStrength: 0.4,
    ),
    Genre.country: GenreModelConfig(
      modelPath: 'assets/models/key_country.tflite',
      whiteningAlpha: 0.5,
      bassSuppression: 120.0,
      hpcpBins: 36,
      smoothingType: TemporalSmoothing.ema,
      smoothingStrength: 0.3,
    ),
    Genre.latin: GenreModelConfig(
      modelPath: 'assets/models/key_latin.tflite',
      whiteningAlpha: 0.6,
      bassSuppression: 100.0,
      hpcpBins: 48,
      smoothingType: TemporalSmoothing.hmm,
      smoothingStrength: 0.5,
    ),
    Genre.world: GenreModelConfig(
      modelPath: 'assets/models/key_world.tflite',
      whiteningAlpha: 0.5,
      bassSuppression: 80.0,
      hpcpBins: 60,
      smoothingType: TemporalSmoothing.dbn,
      smoothingStrength: 0.6,
      classicalWeight: 0.4,
    ),
  };

  // Subgenre-specific overrides
  static const Map<Subgenre, GenreModelConfig> _subgenreConfigs = {
    Subgenre.house: GenreModelConfig(
      modelPath: 'assets/models/key_house.tflite',
      whiteningAlpha: 0.85,
      bassSuppression: 90.0,
      hpcpBins: 48,
      smoothingType: TemporalSmoothing.hmm,
      smoothingStrength: 0.7,
      supportsTuningRegression: true,
    ),
    Subgenre.techno: GenreModelConfig(
      modelPath: 'assets/models/key_techno.tflite',
      whiteningAlpha: 0.9,
      bassSuppression: 80.0,
      hpcpBins: 36,
      smoothingType: TemporalSmoothing.hmm,
      smoothingStrength: 0.8,
      supportsTuningRegression: true,
    ),
    Subgenre.trap: GenreModelConfig(
      modelPath: 'assets/models/key_trap.tflite',
      whiteningAlpha: 0.95,
      bassSuppression: 250.0,
      hpcpBins: 36,
      smoothingType: TemporalSmoothing.hmm,
      smoothingStrength: 0.6,
      supportsTuningRegression: true,
    ),
    Subgenre.bebop: GenreModelConfig(
      modelPath: 'assets/models/key_bebop.tflite',
      whiteningAlpha: 0.4,
      bassSuppression: 60.0,
      hpcpBins: 72,
      smoothingType: TemporalSmoothing.dbn,
      smoothingStrength: 0.9,
      classicalWeight: 0.5,
    ),
  };

  Future<void> initialize() async {
    if (_initialized) return;

    // Build config hierarchy: Subgenre -> Genre -> Default
    for (final genre in Genre.values) {
      _configs[genre] = {};
    }

    // Load genre defaults
    _defaultConfigs.forEach((genre, config) {
      _configs[genre]![Subgenre.none] = config;
    });

    // Load subgenre overrides
    _subgenreConfigs.forEach((subgenre, config) {
      final genre = _getGenreForSubgenre(subgenre);
      if (genre != null) {
        _configs[genre]![subgenre] = config;
      }
    });

    // Try loading custom config from assets
    try {
      final jsonString = await rootBundle.loadString(
        'assets/config/genre_models.json',
      );
      final jsonData = json.decode(jsonString) as Map<String, dynamic>;
      _loadCustomConfigs(jsonData);
    } catch (e) {
      print('No custom genre config found, using defaults: $e');
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
              final subgenre = Subgenre.values.firstWhere(
                (s) => s.name == subgenreStr,
              );
              if (configData is Map<String, dynamic>) {
                _configs[genre]![subgenre] = GenreModelConfig.fromJson(
                  configData,
                );
              }
            } catch (_) {
              // Invalid subgenre
            }
          });
        }
      } catch (_) {
        // Invalid genre
      }
    });
  }

  GenreModelConfig getConfig({
    Genre genre = Genre.auto,
    Subgenre subgenre = Subgenre.none,
  }) {
    if (!_initialized) {
      print('Warning: GenreConfigManager not initialized, using default');
      return const GenreModelConfig(
        modelPath: 'assets/models/key_default.tflite',
      );
    }

    // Auto-detect genre (placeholder - would use BPM, spectral features, etc.)
    if (genre == Genre.auto) {
      genre = _autoDetectGenre();
    }

    // Try subgenre first
    if (subgenre != Subgenre.none) {
      final subConfig = _configs[genre]?[subgenre];
      if (subConfig != null) return subConfig;
    }

    // Fall back to genre
    final genreConfig =
        _configs[genre]?[Subgenre.none] ?? _defaultConfigs[genre];
    if (genreConfig != null) return genreConfig;

    // Fall back to default
    return const GenreModelConfig(
      modelPath: 'assets/models/key_default.tflite',
    );
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
    // Placeholder for auto-detection logic
    // Would analyze spectral features, tempo, etc.
    return Genre.pop; // Default fallback
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
