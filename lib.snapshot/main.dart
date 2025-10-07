import 'package:flutter/material.dart';
import 'theme.dart';
import 'analyzer_page.dart';

void main() => runApp(const HarmoniQApp());

class HarmoniQApp extends StatelessWidget {
  const HarmoniQApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'HarmoniQ',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.light,
      home: const AnalyzerPage(),
    );
  }
}
