import 'package:flutter/material.dart';

const _font = 'JetBrainsMono';

ThemeData _build(Brightness b) {
  final dark = b == Brightness.dark;
  final fg = dark ? Colors.white : Colors.black;
  final bg = dark ? Colors.black : Colors.white;
  final dim = dark ? const Color(0xFF8A8A8A) : const Color(0xFF6A6A6A);
  final panel = dark ? const Color(0xFF161616) : const Color(0xFFF0F0F0);

  final scheme = ColorScheme(
    brightness: b,
    primary: fg,
    onPrimary: bg,
    secondary: fg,
    onSecondary: bg,
    error: fg,
    onError: bg,
    surface: bg,
    onSurface: fg,
    outline: dim,
    outlineVariant: dim,
    surfaceContainerHighest: panel,
    primaryContainer: panel,
    onPrimaryContainer: fg,
  );

  const square = RoundedRectangleBorder(borderRadius: BorderRadius.zero);
  final line = BorderSide(color: fg, width: 1);

  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    fontFamily: _font,
    scaffoldBackgroundColor: bg,
    dividerColor: dim,
    dividerTheme: DividerThemeData(color: dim, thickness: 1, space: 1),
    splashFactory: NoSplash.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: Border(bottom: BorderSide(color: fg, width: 1)),
      titleTextStyle: TextStyle(
        fontFamily: _font,
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: fg,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: bg,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.zero, borderSide: line),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero, borderSide: line),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: fg, width: 2)),
      disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero, borderSide: BorderSide(color: dim)),
      hintStyle: TextStyle(color: dim),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: square),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
          shape: square, backgroundColor: fg, foregroundColor: bg),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: square, foregroundColor: fg),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: bg,
      foregroundColor: fg,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero, side: line),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero, side: line),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: fg,
      contentTextStyle: TextStyle(fontFamily: _font, color: bg),
      shape: square,
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: fg,
      linearTrackColor: panel,
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero, side: BorderSide(color: fg)),
      backgroundColor: bg,
      labelStyle: TextStyle(fontFamily: _font, color: fg, fontSize: 12),
    ),
  );
}

final lightTheme = _build(Brightness.light);
final darkTheme = _build(Brightness.dark);

/// Bunny logo drawn at half opacity behind the page content.
/// The artwork is black-on-white, so it is inverted in dark mode.
class BunnyBackground extends StatelessWidget {
  final Widget child;
  const BunnyBackground({super.key, required this.child});

  static const _invert = ColorFilter.matrix(<double>[
    -1, 0, 0, 0, 255, //
    0, -1, 0, 0, 255,
    0, 0, -1, 0, 255,
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget img = Image.asset('assets/Bunny.png', fit: BoxFit.contain);
    if (dark) img = ColorFiltered(colorFilter: _invert, child: img);

    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Opacity(opacity: 0.25, child: img),
              ),
            ),
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}
