import 'dart:io';
import 'package:flutter/material.dart';

class SystemAudioPage extends StatelessWidget {
  const SystemAudioPage({super.key});
  @override
  Widget build(BuildContext context) {
    final supported = !Platform.isIOS;
    return Scaffold(
      appBar: AppBar(title: const Text('System Audio')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            supported
                ? 'System audio capture is not implemented on this build.'
                : 'System audio capture is not available on iOS for third-party apps.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16),
          ),
        ),
      ),
    );
  }
}
