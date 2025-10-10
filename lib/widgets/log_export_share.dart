// lib/widgets/log_export_share.dart
// Quick “Export + Share Logs” controls for HarmoniQ.

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../logger.dart'; // uses HarmoniQLogger

/// Call this to export the in-memory session logs to CSV/JSON and open
/// the system share sheet for AirDrop / Mail / Drive, etc.
Future<void> exportAndShareLogs(BuildContext context,
    {bool asJson = false}) async {
  final scaffold = ScaffoldMessenger.of(context);

  try {
    // Create a predictable filename so we can share it right away.
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final ext = asJson ? 'json' : 'csv';
    final fileName = 'harmoniq_export_$ts.$ext';

    // Ask logger to write the export file.
    await HarmoniQLogger().exportResults(customPath: fileName, asJson: asJson);

    // Locate the file path where exportResults() writes.
    final docs = await getApplicationDocumentsDirectory();
    final exportDir = Directory('${docs.path}/harmoniq_exports');
    final file = File('${exportDir.path}/$fileName');

    if (!await file.exists()) {
      scaffold.showSnackBar(
        const SnackBar(content: Text('Export failed: file not found')),
      );
      return;
    }

    // Share the exported file.
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'HarmoniQ Test Logs (${asJson ? "JSON" : "CSV"})',
      text: 'Exported from HarmoniQ • ${file.uri.pathSegments.last}',
    );

    scaffold.showSnackBar(
      SnackBar(
        content: Text('Exported ${asJson ? "JSON" : "CSV"} → ${file.path}'),
        duration: const Duration(seconds: 3),
      ),
    );
  } catch (e) {
    scaffold.showSnackBar(
      SnackBar(content: Text('Export error: $e')),
    );
  }
}

/// AppBar action with a popup menu (CSV / JSON).
class LogExportMenuAction extends StatelessWidget {
  const LogExportMenuAction({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Export logs',
      onSelected: (v) {
        final asJson = v == 'json';
        exportAndShareLogs(context, asJson: asJson);
      },
      itemBuilder: (ctx) => const [
        PopupMenuItem(value: 'csv', child: Text('Export & Share CSV')),
        PopupMenuItem(value: 'json', child: Text('Export & Share JSON')),
      ],
      icon: const Icon(Icons.ios_share),
    );
  }
}

/// Floating action button variant (exports CSV by default).
class LogExportFab extends StatelessWidget {
  final bool asJson;
  const LogExportFab({super.key, this.asJson = false});

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: () => exportAndShareLogs(context, asJson: asJson),
      icon: const Icon(Icons.ios_share),
      label: Text('Share ${asJson ? "JSON" : "CSV"}'),
    );
  }
}
