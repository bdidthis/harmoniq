// lib/dev_offline.dart
import 'package:flutter/material.dart';
import 'offline_file_analyzer_page.dart';

/// Simple entry you can push from anywhere to open the offline analyzer.
class DevOfflineEntry extends StatelessWidget {
  const DevOfflineEntry({super.key});

  @override
  Widget build(BuildContext context) => const OfflineFileAnalyzerPage();
}
