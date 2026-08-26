import 'package:flutter/material.dart';

const easyPrivacyGreen = Color(0xFF238344);
const easyPrivacyDarkGreen = Color(0xFF155C30);
const easyPrivacySoftGreen = Color(0xFFEAF5EC);
const easyPrivacyInk = Color(0xFF171A18);
const easyPrivacyMuted = Color(0xFF626A64);
const easyPrivacyBorder = Color(0xFFE0E5E1);
const easyPrivacySurface = Color(0xFFFAFCFA);

ThemeData buildEasyPrivacyTheme() {
  final colorScheme =
      ColorScheme.fromSeed(
        seedColor: easyPrivacyGreen,
        brightness: Brightness.light,
        surface: Colors.white,
      ).copyWith(
        primary: easyPrivacyGreen,
        onPrimary: Colors.white,
        secondary: easyPrivacyDarkGreen,
        outline: easyPrivacyBorder,
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: easyPrivacySurface,
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: easyPrivacySurface,
    dividerColor: easyPrivacyBorder,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 38,
        fontWeight: FontWeight.w700,
        height: 1.08,
        letterSpacing: -1.2,
        color: easyPrivacyInk,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: easyPrivacyInk,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: easyPrivacyInk,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: easyPrivacyInk,
      ),
      bodyLarge: TextStyle(fontSize: 16, color: easyPrivacyInk, height: 1.45),
      bodyMedium: TextStyle(
        fontSize: 14,
        color: easyPrivacyMuted,
        height: 1.45,
      ),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    cardTheme: const CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(18)),
        side: BorderSide(color: easyPrivacyBorder),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: easyPrivacyBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: easyPrivacyBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: easyPrivacyGreen, width: 2),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        side: const BorderSide(color: easyPrivacyBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
