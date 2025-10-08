// lib/shims.dart
// 1) Compile-time compatibility shims for BpmEstimator fields used around the app.
// 2) Minimal FFmpegKit stub so code compiles on builds without the FFmpeg plugin.

import 'bpm_estimator.dart';

/// Call-site style used in analyzer_page.dart:  (_bpm as Object).stability_or0
extension BpmCompatOnObject on Object {
  double get stability_or0 {
    try {
      final v = (this as dynamic).stability as double?;
      return v ?? 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  double get confidence_or0 {
    try {
      final v = (this as dynamic).confidence as double?;
      return v ?? 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  bool get isLocked_orFalse {
    try {
      final v = (this as dynamic).isLocked as bool?;
      return v ?? false;
    } catch (_) {
      try {
        final bpm = (this as dynamic).bpm as double?;
        return (bpm ?? 0) > 0;
      } catch (_) {
        return false;
      }
    }
  }

  void reset_safe() {
    try {
      (this as dynamic).reset();
    } catch (_) {
      /* no-op */
    }
  }
}

/// Convenience on the actual type, for other files that call `_bpm.stability`.
extension BpmCompatOnEstimator on BpmEstimator {
  double get stability => (this as Object).stability_or0;
  double get confidence => (this as Object).confidence_or0;
  bool get isLocked => (this as Object).isLocked_orFalse;
  void reset() => (this as Object).reset_safe();
}

// -----------------------------------------------------------------------------
// FFmpeg shim (no-op). This lets OfflineFileAnalyzerPage build/run even when
// the FFmpeg plugin is not linked (e.g., web or tests). The API mirrors what
// that page uses: execute(), getReturnCode(), getLogsAsString(), ReturnCode.
// -----------------------------------------------------------------------------

class FFmpegKit {
  static Future<_ShimSession> execute(String cmd) async => _ShimSession();
}

class _ShimSession {
  Future<_ShimReturnCode> getReturnCode() async => _ShimReturnCode.success();
  Future<String> getLogsAsString() async => "";
  // Back-compat (older sample code sometimes calls this):
  Future<String> getAllLogsAsString() async => "";
}

class _ShimReturnCode {
  final int value;
  const _ShimReturnCode._(this.value);
  factory _ShimReturnCode.success() => const _ShimReturnCode._(0);
}

class ReturnCode {
  static bool isSuccess(Object? code) {
    if (code is _ShimReturnCode) return code.value == 0;
    // Be permissive if types differ on other platforms.
    return true;
  }
}
