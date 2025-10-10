import 'dart:async';

class ShareIntake {
  static final _controller = StreamController<Uri>.broadcast();
  static Stream<Uri> get stream => _controller.stream;
  static Future<void> init() async {}
  static Future<void> start() => init();
  static Future<void> dispose() async {
    await _controller.close();
  }
}
