// lib/main.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'analyzer_page.dart';
import 'theme.dart';

void main() {
  // Rich console logging for framework errors
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
    if (kDebugMode) {
      debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    }
  };

  // A friendlier in-app error widget than the default red screen
  ErrorWidget.builder = (FlutterErrorDetails errorDetails) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'Something went wrong',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    kDebugMode
                        ? errorDetails.exception.toString()
                        : 'Please check the console for details',
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  if (kDebugMode) ...[
                    const SizedBox(height: 16),
                    // Use Flexible so we never assert on layout
                    Flexible(
                      child: SingleChildScrollView(
                        child: Text(
                          errorDetails.stack?.toString() ?? '',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  };

  // Catch anything that escapes FlutterError and print the stack
  runZonedGuarded(() {
    runApp(const MyApp());
  }, (error, stack) {
    debugPrint('🧨 Uncaught zone error: $error');
    debugPrintStack(stackTrace: stack);
    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'HarmoniQ',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      // You can switch to system if you want automatic light/dark:
      // themeMode: ThemeMode.system,
      themeMode: ThemeMode.dark,
      home: const AnalyzerPage(),
    );
  }
}
