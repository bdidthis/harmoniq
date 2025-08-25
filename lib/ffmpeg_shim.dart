class FFmpegKit {
  static Future<_ShimSession> execute(String cmd) async => _ShimSession();
}
class _ShimSession {
  Future<_ShimReturnCode> getReturnCode() async => _ShimReturnCode();
  Future<String> getAllLogsAsString() async => "";
}
class _ShimReturnCode {}
class ReturnCode {
  static bool isSuccess(Object? _) => true;
}
