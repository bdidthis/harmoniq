import 'package:flutter/material.dart';

class AppTheme {
  static const seed = Color(0xFF7C3AED);
  static ThemeData light = ThemeData(
      useMaterial3: false,
      colorScheme:
          ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light));
  static ThemeData dark = ThemeData(
      useMaterial3: false,
      colorScheme:
          ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark));
}
