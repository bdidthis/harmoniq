// lib/logger.dart
// Structured logging system aligned with Excel test sheets

import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

enum LogLevel { debug, info, warning, error }

enum TestType { shortTerm, mediumTerm, longTerm }

class TestLogEntry {
  final DateTime timestamp;
  final TestType testType;
  final String testId;
  final String audioSource;
  final String sourceType; // 'metronome', 'song', 'live', 'synthetic'

  // Genre/Model
  final String genre;
  final String subgenre;
  final String modelUsed;
  final String fallbackModel;
  final bool classicalEnabled;
  final double classicalWeight;

  // BPM Metrics
  final double? trueBpm;
  final double? detectedBpm;
  final double? bpmError;
  final double? bpmStability;
  final double? bpmConfidence;
  final int? bpmLockFrames;
  final bool? bpmLocked;

  // Key Metrics
  final String? trueKey;
  final String? detectedKey;
  final double? keyConfidence;
  final List<String>? topThreeKeys;
  final List<double>? topThreeConfidences;
  final double? tuningOffset;
  final int? keyLockFrames;

  // Temporal Smoothing
  final String smoothingType;
  final double smoothingStrength;

  // Performance Metrics
  final double? cpuUsage;
  final double? memoryUsage;
  final double? processingLatency;
  final int? droppedFrames;

  // Additional Parameters
  final double? whiteningAlpha;
  final double? bassSuppression;
  final int? hpcpBins;
  final Map<String, dynamic>? customParams;

  TestLogEntry({
    required this.timestamp,
    required this.testType,
    required this.testId,
    required this.audioSource,
    required this.sourceType,
    required this.genre,
    required this.subgenre,
    required this.modelUsed,
    required this.fallbackModel,
    required this.classicalEnabled,
    required this.classicalWeight,
    this.trueBpm,
    this.detectedBpm,
    this.bpmError,
    this.bpmStability,
    this.bpmConfidence,
    this.bpmLockFrames,
    this.bpmLocked,
    this.trueKey,
    this.detectedKey,
    this.keyConfidence,
    this.topThreeKeys,
    this.topThreeConfidences,
    this.tuningOffset,
    this.keyLockFrames,
    required this.smoothingType,
    required this.smoothingStrength,
    this.cpuUsage,
    this.memoryUsage,
    this.processingLatency,
    this.droppedFrames,
    this.whiteningAlpha,
    this.bassSuppression,
    this.hpcpBins,
    this.customParams,
  });

  // Safe JSON encoding to prevent crashes
  String? _safeJsonEncode(Map<String, dynamic>? data) {
    if (data == null) return null;
    try {
      return json.encode(data);
    } catch (e) {
      return json.encode({
        'error': 'Failed to serialize customParams',
        'detail': e.toString()
      });
    }
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'test_type': testType.name,
        'test_id': testId,
        'audio_source': audioSource,
        'source_type': sourceType,
        'genre': genre,
        'subgenre': subgenre,
        'model_used': modelUsed,
        'fallback_model': fallbackModel,
        'classical_enabled': classicalEnabled,
        'classical_weight': classicalWeight,
        'true_bpm': trueBpm,
        'detected_bpm': detectedBpm,
        'bpm_error': bpmError,
        'bpm_stability': bpmStability,
        'bpm_confidence': bpmConfidence,
        'bpm_lock_frames': bpmLockFrames,
        'bpm_locked': bpmLocked,
        'true_key': trueKey,
        'detected_key': detectedKey,
        'key_confidence': keyConfidence,
        'top_three_keys': topThreeKeys?.join('|'),
        'top_three_confidences': topThreeConfidences?.join('|'),
        'tuning_offset': tuningOffset,
        'key_lock_frames': keyLockFrames,
        'smoothing_type': smoothingType,
        'smoothing_strength': smoothingStrength,
        'cpu_usage': cpuUsage,
        'memory_usage': memoryUsage,
        'processing_latency': processingLatency,
        'dropped_frames': droppedFrames,
        'whitening_alpha': whiteningAlpha,
        'bass_suppression': bassSuppression,
        'hpcp_bins': hpcpBins,
        'custom_params': _safeJsonEncode(customParams),
      };

  String toCsv() {
    final values = [
      timestamp.toIso8601String(),
      testType.name,
      testId,
      audioSource,
      sourceType,
      genre,
      subgenre,
      modelUsed,
      fallbackModel,
      classicalEnabled.toString(),
      classicalWeight.toString(),
      trueBpm?.toString() ?? '',
      detectedBpm?.toString() ?? '',
      bpmError?.toString() ?? '',
      bpmStability?.toString() ?? '',
      bpmConfidence?.toString() ?? '',
      bpmLockFrames?.toString() ?? '',
      bpmLocked?.toString() ?? '',
      trueKey ?? '',
      detectedKey ?? '',
      keyConfidence?.toString() ?? '',
      topThreeKeys?.join('|') ?? '',
      topThreeConfidences?.map((c) => c.toStringAsFixed(3)).join('|') ?? '',
      tuningOffset?.toString() ?? '',
      keyLockFrames?.toString() ?? '',
      smoothingType,
      smoothingStrength.toString(),
      cpuUsage?.toString() ?? '',
      memoryUsage?.toString() ?? '',
      processingLatency?.toString() ?? '',
      droppedFrames?.toString() ?? '',
      whiteningAlpha?.toString() ?? '',
      bassSuppression?.toString() ?? '',
      hpcpBins?.toString() ?? '',
      _safeJsonEncode(customParams) ?? '',
    ];

    return values.map((v) => '"${v.replaceAll('"', '""')}"').join(',');
  }

  static String getCsvHeader() {
    return [
      'timestamp',
      'test_type',
      'test_id',
      'audio_source',
      'source_type',
      'genre',
      'subgenre',
      'model_used',
      'fallback_model',
      'classical_enabled',
      'classical_weight',
      'true_bpm',
      'detected_bpm',
      'bpm_error',
      'bpm_stability',
      'bpm_confidence',
      'bpm_lock_frames',
      'bpm_locked',
      'true_key',
      'detected_key',
      'key_confidence',
      'top_three_keys',
      'top_three_confidences',
      'tuning_offset',
      'key_lock_frames',
      'smoothing_type',
      'smoothing_strength',
      'cpu_usage',
      'memory_usage',
      'processing_latency',
      'dropped_frames',
      'whitening_alpha',
      'bass_suppression',
      'hpcp_bins',
      'custom_params',
    ].join(',');
  }
}

class HarmoniQLogger {
  static final HarmoniQLogger _instance = HarmoniQLogger._internal();
  factory HarmoniQLogger() => _instance;
  HarmoniQLogger._internal();

  final List<TestLogEntry> _entries = [];
  String? _sessionId;
  File? _currentLogFile;
  bool _consoleLoggingEnabled = true;
  bool _fileLoggingEnabled = true;

  Future<void> initialize({
    bool enableConsole = true,
    bool enableFile = true,
  }) async {
    _consoleLoggingEnabled = enableConsole;
    _fileLoggingEnabled = enableFile;
    _sessionId = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());

    if (_fileLoggingEnabled) {
      await _createLogFile();
    }
  }

  Future<void> _createLogFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/harmoniq_logs');

      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }

      final fileName = 'harmoniq_$_sessionId.csv';
      _currentLogFile = File('${logDir.path}/$fileName');

      await _currentLogFile!.writeAsString('${TestLogEntry.getCsvHeader()}\n');

      print('Log file created: ${_currentLogFile!.path}');
    } catch (e) {
      print('Failed to create log file: $e');
      _fileLoggingEnabled = false;
    }
  }

  Future<void> logTestResult(TestLogEntry entry) async {
    _entries.add(entry);

    if (_consoleLoggingEnabled) {
      _logToConsole(entry);
    }

    if (_fileLoggingEnabled && _currentLogFile != null) {
      await _logToFile(entry);
    }
  }

  void _logToConsole(TestLogEntry entry) {
    final output = StringBuffer();
    output.writeln('========================================');
    output.writeln('  HarmoniQ Test Result');
    output.writeln('========================================');
    output.writeln('  Test: ${entry.testId}');
    output.writeln('  Type: ${entry.testType.name}');
    output.writeln('  Genre: ${entry.genre}/${entry.subgenre}');
    output.writeln('  Model: ${entry.modelUsed.split('/').last}');
    output.writeln('----------------------------------------');

    if (entry.detectedBpm != null) {
      output.writeln(
        '  BPM: ${entry.detectedBpm!.toStringAsFixed(1)} (error: ${entry.bpmError?.toStringAsFixed(1) ?? "N/A"})',
      );
      output.writeln(
        '  Stability: ${((entry.bpmStability ?? 0) * 100).toStringAsFixed(0)}%',
      );
    }

    if (entry.detectedKey != null) {
      output.writeln(
        '  Key: ${entry.detectedKey} (${((entry.keyConfidence ?? 0) * 100).toStringAsFixed(0)}%)',
      );
      output.writeln(
        '  Tuning: ${entry.tuningOffset?.toStringAsFixed(1) ?? "0"} cents',
      );

      if (entry.topThreeKeys != null && entry.topThreeKeys!.isNotEmpty) {
        output.writeln('  Alternates:');
        for (int i = 0; i < entry.topThreeKeys!.length && i < 3; i++) {
          final conf = entry.topThreeConfidences?[i] ?? 0;
          output.writeln(
            '    ${i + 1}. ${entry.topThreeKeys![i]} (${(conf * 100).toStringAsFixed(0)}%)',
          );
        }
      }
    }

    output.writeln('========================================');
    print(output.toString());
  }

  Future<void> _logToFile(TestLogEntry entry) async {
    if (_currentLogFile == null) return;

    try {
      await _currentLogFile!.writeAsString(
        '${entry.toCsv()}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      print('Failed to write to log file: $e');
      _fileLoggingEnabled = false;
    }
  }

  Future<void> exportResults({String? customPath, bool asJson = false}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final exportDir = Directory('${dir.path}/harmoniq_exports');

      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }

      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final format = asJson ? 'json' : 'csv';
      final fileName = customPath ?? 'harmoniq_export_$timestamp.$format';
      final file = File('${exportDir.path}/$fileName');

      if (asJson) {
        final jsonData = _entries.map((e) => e.toJson()).toList();
        await file.writeAsString(json.encode(jsonData));
      } else {
        final csvLines = [TestLogEntry.getCsvHeader()];
        csvLines.addAll(_entries.map((e) => e.toCsv()));
        await file.writeAsString(csvLines.join('\n'));
      }

      print('Results exported to: ${file.path}');
    } catch (e) {
      print('Failed to export results: $e');
    }
  }

  List<TestLogEntry> getEntries({
    TestType? type,
    String? genre,
    DateTime? startTime,
    DateTime? endTime,
  }) {
    return _entries.where((entry) {
      if (type != null && entry.testType != type) return false;
      if (genre != null && entry.genre != genre) return false;
      if (startTime != null && entry.timestamp.isBefore(startTime))
        return false;
      if (endTime != null && entry.timestamp.isAfter(endTime)) return false;
      return true;
    }).toList();
  }

  void clearLogs() {
    _entries.clear();
  }

  Future<void> close() async {
    if (_currentLogFile != null) {
      print('Closing log file: ${_currentLogFile!.path}');
    }
    _entries.clear();
  }
}
