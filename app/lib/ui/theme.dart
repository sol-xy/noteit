import 'package:material_ui/material_ui.dart';

class NoteItTheme {
  static const _accent = Color(0xFF2C5F4F);
  static const _darkAccent = Color(0xFF4C9A80);

  static ThemeData light() {
    const scheme = ColorScheme.light(
      primary: _accent,
      onPrimary: Colors.white,
      secondary: Color(0xFF5B6E65),
      surface: Color(0xFFF8F7F4),
      surfaceContainerHighest: Color(0xFFEEEBE4),
      onSurface: Color(0xFF1F1E1B),
      outline: Color(0xFFE0DDD4),
      error: Color(0xFFB43C3C),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF8F7F4),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFF8F7F4),
        foregroundColor: Color(0xFF1F1E1B),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFFE4E0D8)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE4E0D8)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE4E0D8)),
        ),
      ),
    );
  }

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: _darkAccent,
      onPrimary: Color(0xFF0E1D17),
      secondary: Color(0xFF8AA89C),
      surface: Color(0xFF141413),
      surfaceContainerHighest: Color(0xFF252522),
      onSurface: Color(0xFFEFEDE8),
      outline: Color(0xFF32312D),
      error: Color(0xFFD96464),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF141413),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF141413),
        foregroundColor: Color(0xFFEFEDE8),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1D1D1B),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFF32312D)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1D1D1B),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF32312D)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF32312D)),
        ),
      ),
    );
  }
}
