import 'package:flutter/material.dart';

/// Quiet surfaces and a single action color keep the question at the center.
ThemeData buildAppTheme() {
  const ink = Color(0xFF1D1D1F);
  const muted = Color(0xFF626268);
  const accent = Color(0xFF0066CC);
  const canvas = Color(0xFFF5F5F7);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.light,
      ).copyWith(
        primary: accent,
        onPrimary: Colors.white,
        primaryContainer: const Color(0xFFE8F2FF),
        onPrimaryContainer: const Color(0xFF004A99),
        secondary: muted,
        surface: Colors.white,
        onSurface: ink,
        onSurfaceVariant: muted,
        surfaceContainerHighest: const Color(0xFFEEF0F3),
        surfaceContainerLow: const Color(0xFFF9F9FB),
        outline: const Color(0xFF85858C),
        outlineVariant: const Color(0xFFE2E3E7),
        error: const Color(0xFFB42318),
      );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final text = base.textTheme.apply(bodyColor: ink, displayColor: ink);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  final fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: const BorderSide(color: Color(0xFF8B8B93), width: .75),
  );
  return base.copyWith(
    scaffoldBackgroundColor: canvas,
    textTheme: text.copyWith(
      headlineLarge: text.headlineLarge?.copyWith(
        fontSize: 36,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.1,
        height: 1.2,
      ),
      headlineMedium: text.headlineMedium?.copyWith(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -.8,
        height: 1.25,
      ),
      headlineSmall: text.headlineSmall?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -.5,
        height: 1.3,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -.3,
        height: 1.35,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -.2,
        height: 1.4,
      ),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 16, height: 1.55),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.5),
      bodySmall: text.bodySmall?.copyWith(
        fontSize: 12,
        color: muted,
        height: 1.5,
      ),
      labelLarge: text.labelLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 64,
      backgroundColor: canvas,
      foregroundColor: ink,
      titleTextStyle: TextStyle(
        color: ink,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -.3,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF1F2F5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      focusedBorder: fieldBorder.copyWith(
        borderSide: const BorderSide(color: accent, width: 2),
      ),
      errorBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
      labelStyle: const TextStyle(color: muted),
      prefixIconColor: muted,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 50),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
        shape: shape,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: shape,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: .7,
      space: 24,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainerHighest,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      labelStyle: const TextStyle(
        color: muted,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
    ),
    navigationDrawerTheme: NavigationDrawerThemeData(
      backgroundColor: Colors.white,
      indicatorColor: scheme.primaryContainer,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: accent,
      linearMinHeight: 3,
    ),
  );
}
