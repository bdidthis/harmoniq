import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'dart:io' show Platform;

class SystemAudioPage extends StatelessWidget {
  const SystemAudioPage({super.key});

  @override
  Widget build(BuildContext context) {
    // System audio capture not supported on iOS or Web in third-party apps.
    final supported = !kIsWeb && !Platform.isIOS;

    return Scaffold(
      appBar: AppBar(title: const Text('System Audio')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            supported
                ? 'System audio capture is not implemented on this build.'
                : (kIsWeb
                    ? 'System audio capture is not available on the Web.'
                    : 'System audio capture is not available on iOS for third-party apps.'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16),
          ),
        ),
      ),
    );
  }
}
