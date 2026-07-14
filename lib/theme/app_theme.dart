import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart';

/// User-selectable chrome theme. `system` tracks the OS light/dark setting; the
/// rest pin a specific palette. `oled` is a true-black variant of the dark
/// theme tuned for OLED panels (pure #000000 surfaces leave pixels unlit).
enum AppThemeChoice { system, light, dark, oled }

/// User-selectable UI icon density. `small` is the factory default; `medium`
/// and `large` multiply every chrome icon size by 1.25× and 1.5× respectively.
enum AppIconScale { small, medium, large }

/// User-selectable layout for the terminal smart keyboard keys.
enum TerminalShortcutLayout { classic, dpadLeft, dpadRight }

/// One full set of chrome colors. The app ships three: the original monochrome
/// "DARKROOM" dark palette, an inverted "PAPER" light palette, and a true-black
/// "OLED" variant of the dark theme.
class _Palette {
  final Color ink;
  final Color panel;
  final Color panelHi;
  final Color hairline;
  final Color bone;
  final Color muted;
  final Color faint;

  const _Palette({
    required this.ink,
    required this.panel,
    required this.panelHi,
    required this.hairline,
    required this.bone,
    required this.muted,
    required this.faint,
  });
}

/// Monochrome Swiss palette. No hue — emphasis comes from inversion (bone block
/// on ink) rather than an accent color.
///
/// The fields are intentionally **mutable**: the app supports a light/dark/
/// system theme switch, and almost every widget reads these statics directly
/// (e.g. `AppColors.ink`). [apply] swaps the active palette in place so those
/// references re-resolve on the next build — there is no need to thread a theme
/// object through the widget tree. Because they are no longer compile-time
/// constants, call sites must not wrap them in `const`.
class AppColors {
  AppColors._();

  static const _Palette _dark = _Palette(
    ink: Color(0xFF0A0A0A), // base background (tinta)
    panel: Color(0xFF121212), // panel surface
    panelHi: Color(0xFF1A1A1A), // elevated row within a panel
    hairline: Color(0xFF2A2A2A), // 1px borders everywhere
    bone: Color(0xFFECE7DD), // primary text / element (hueso)
    muted: Color(0xFF7A766E), // secondary text, metadata, inactive
    faint: Color(0xFF4A4742), // faint icons / dividers
  );

  /// Inverted "PAPER" palette: warm off-white surfaces, near-black ink as the
  /// primary element. Mirrors the dark palette's contrast relationships.
  static const _Palette _light = _Palette(
    ink: Color(0xFFF4F1EA), // paper background
    panel: Color(0xFFEAE6DC), // panel surface
    panelHi: Color(0xFFDFDACE), // elevated row within a panel
    hairline: Color(0xFFCBC5B7), // 1px borders everywhere
    bone: Color(0xFF1A1916), // primary text / element (near-black ink)
    muted: Color(0xFF6E6A61), // secondary text, metadata, inactive
    faint: Color(0xFFA9A294), // faint icons / dividers
  );

  /// True-black "OLED" palette. Keeps DARKROOM's ink/bone contrast but pushes
  /// every surface to pure black so OLED pixels switch fully off; panels are
  /// delineated by the hairline borders rather than by elevation.
  static const _Palette _oled = _Palette(
    ink: Color(0xFF000000), // pure black background
    panel: Color(0xFF000000), // panel surface — also pure black
    panelHi: Color(0xFF101010), // barely-elevated row within a panel
    hairline: Color(0xFF262626), // 1px borders carry the structure here
    bone: Color(0xFFECE7DD), // primary text / element (hueso)
    muted: Color(0xFF7A766E), // secondary text, metadata, inactive
    faint: Color(0xFF4A4742), // faint icons / dividers
  );

  static Color ink = _dark.ink;
  static Color panel = _dark.panel;
  static Color panelHi = _dark.panelHi;
  static Color hairline = _dark.hairline;
  static Color bone = _dark.bone;
  static Color muted = _dark.muted;
  static Color faint = _dark.faint;
  static Color accent = _dark.bone;

  static const List<(String, String, Color)> accentPresets = [
    ('auto', 'MONOCROMO', Color(0xFFECE7DD)),
    ('red', 'ROJO SUIZO', Color(0xFFE63946)),
    ('orange', 'NARANJA INT', Color(0xFFFF5E00)),
    ('green', 'VERDE MATRIX', Color(0xFF00FF66)),
    ('blue', 'AZUL BAUHAUS', Color(0xFF0055FF)),
    ('yellow', 'AMARILLO ACID', Color(0xFFEBFF00)),
    ('purple', 'VIOLETA', Color(0xFF8B5CF6)),
  ];

  /// Reserved single warm signal — only for irreversible/destructive accents.
  /// Constant across themes so it can still be used in `const` widgets.
  static const Color danger = Color(0xFFC0392B);

  static Brightness brightness = Brightness.dark;

  /// Whether the active palette is the true-black OLED variant. The terminal
  /// theme reads this to pick a pure-black background while keeping the dark
  /// [Brightness] shared with DARKROOM.
  static bool oledActive = false;

  /// The [Brightness] that pairs with [choice]; only [AppThemeChoice.system]
  /// consults the OS [platformBrightness]. OLED is a dark theme.
  static Brightness brightnessFor(
      AppThemeChoice choice, Brightness platformBrightness) {
    switch (choice) {
      case AppThemeChoice.light:
        return Brightness.light;
      case AppThemeChoice.dark:
      case AppThemeChoice.oled:
        return Brightness.dark;
      case AppThemeChoice.system:
        return platformBrightness;
    }
  }

  /// Swap the active chrome palette for [choice]. [platformBrightness] resolves
  /// the `system` option. Call before building the [MaterialApp] so the static
  /// color references resolve to the chosen theme.
  static void apply(AppThemeChoice choice, Brightness platformBrightness, {String? accentColorHex}) {
    oledActive = choice == AppThemeChoice.oled;
    final _Palette p;
    switch (choice) {
      case AppThemeChoice.light:
        p = _light;
      case AppThemeChoice.dark:
        p = _dark;
      case AppThemeChoice.oled:
        p = _oled;
      case AppThemeChoice.system:
        p = platformBrightness == Brightness.light ? _light : _dark;
    }
    brightness = brightnessFor(choice, platformBrightness);
    ink = p.ink;
    panel = p.panel;
    panelHi = p.panelHi;
    hairline = p.hairline;
    bone = p.bone;
    muted = p.muted;
    faint = p.faint;

    // Resolve accent color
    if (accentColorHex == null || accentColorHex == 'auto') {
      accent = p.bone;
    } else {
      final preset = accentPresets.firstWhere(
        (e) => e.$1 == accentColorHex,
        orElse: () => ('', '', const Color(0xFFECE7DD)),
      );
      if (preset.$1.isNotEmpty) {
        accent = preset.$3;
      } else {
        try {
          accent = Color(int.parse(accentColorHex));
        } catch (_) {
          accent = p.bone;
        }
      }
    }
  }
}

/// Typography helpers built on google_fonts:
/// - display: Anton (condensed ultra-bold) for giant screen wordmarks
/// - label/body: Archivo (neutral grotesque)
/// - mono: JetBrains Mono for technical data (paths, host:port, sizes, keycaps)
///
/// Color parameters are nullable and resolved against [AppColors] at call time
/// (not via default values) so they follow the active light/dark palette.
class AppText {
  AppText._();

  static const List<(String, String)> monoFontOptions = [
    ('cascadia', 'Cascadia Code'),
    ('jetbrains', 'JetBrains Mono'),
    ('firacode', 'Fira Code'),
    ('sourcecode', 'Source Code Pro'),
    ('inconsolata', 'Inconsolata'),
    ('anonymous', 'Anonymous Pro'),
  ];

  static String resolveMonoFontFamily(String choice) {
    switch (choice) {
      case 'jetbrains':
        return GoogleFonts.jetBrainsMono().fontFamily ?? 'monospace';
      case 'firacode':
        return GoogleFonts.firaCode().fontFamily ?? 'monospace';
      case 'sourcecode':
        return GoogleFonts.sourceCodePro().fontFamily ?? 'monospace';
      case 'inconsolata':
        return GoogleFonts.inconsolata().fontFamily ?? 'monospace';
      case 'anonymous':
        return GoogleFonts.anonymousPro().fontFamily ?? 'monospace';
      case 'cascadia':
      default:
        return 'CascadiaCode';
    }
  }

  /// Giant uppercase wordmark, tight negative tracking (DARKROOM look).
  static TextStyle display(
    double size, {
    Color? color,
    double height = 0.92,
  }) =>
      GoogleFonts.anton(
        fontSize: size,
        height: height,
        letterSpacing: -size * 0.02,
        color: color ?? AppColors.bone,
      );

  /// Small uppercase grotesque label with positive tracking.
  static TextStyle label(
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w700,
    double spacing = 1.2,
  }) =>
      GoogleFonts.archivo(
        fontSize: size,
        fontWeight: weight,
        letterSpacing: spacing,
        color: color ?? AppColors.muted,
      );

  /// Regular reading / control text.
  static TextStyle body(
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w500,
  }) =>
      GoogleFonts.archivo(
        fontSize: size,
        fontWeight: weight,
        color: color ?? AppColors.bone,
      );

  /// Monospace technical text.
  static TextStyle mono(
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w500,
    double spacing = 0.0,
  }) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size,
        fontWeight: weight,
        letterSpacing: spacing,
        color: color ?? AppColors.bone,
      );

  /// Font family name for the terminal emulator (xterm needs a family string).
  static String get monoFamily => GoogleFonts.jetBrainsMono().fontFamily!;

  /// Cascadia Code — bundled as an asset font (see pubspec). Used by the
  /// terminal emulator and the code editor for a Warp/Termux-like feel.
  static const String cascadiaFamily = 'CascadiaCode';
}

/// Terminal color schemes. The terminal *content* keeps its own palette so
/// program output (ls, vim, git) stays readable; the chrome around it follows
/// the app theme. [forBrightness] returns the variant that pairs with the
/// active app theme.
class AppTerminalTheme {
  AppTerminalTheme._();

  /// Picks the terminal palette that pairs with the active chrome: PAPER on a
  /// light theme, the true-black [oled] variant when the OLED palette is
  /// active, otherwise the standard [warp] dark theme.
  static TerminalTheme forBrightness(Brightness b) {
    if (b == Brightness.light) return paper;
    return AppColors.oledActive ? oled : warp;
  }

  /// User-selectable fixed schemes (Settings → Terminal). 'auto' is not here:
  /// it means "follow the app theme" and resolves through [forBrightness].
  static const Map<String, TerminalTheme> schemes = {
    'dracula': dracula,
    'gruvbox': gruvbox,
    'nord': nord,
  };

  /// (id, label) pairs for the Settings selector, 'auto' first.
  static const List<(String, String)> schemeOptions = [
    ('auto', 'AUTO'),
    ('dracula', 'DRACULA'),
    ('gruvbox', 'GRUVBOX'),
    ('nord', 'NORD'),
  ];

  /// Resolves a persisted scheme id to a palette; 'auto' (and anything
  /// unknown) falls back to the theme-paired palette.
  static TerminalTheme byId(String id, Brightness b, {Color? accentColor}) {
    final theme = schemes[id] ?? forBrightness(b);
    if (accentColor != null) {
      return TerminalTheme(
        cursor: accentColor,
        selection: accentColor.withValues(alpha: 0.25),
        foreground: theme.foreground,
        background: theme.background,
        black: theme.black,
        red: theme.red,
        green: theme.green,
        yellow: theme.yellow,
        blue: theme.blue,
        magenta: theme.magenta,
        cyan: theme.cyan,
        white: theme.white,
        brightBlack: theme.brightBlack,
        brightRed: theme.brightRed,
        brightGreen: theme.brightGreen,
        brightYellow: theme.brightYellow,
        brightBlue: theme.brightBlue,
        brightMagenta: theme.brightMagenta,
        brightCyan: theme.brightCyan,
        brightWhite: theme.brightWhite,
        searchHitBackground: theme.searchHitBackground,
        searchHitBackgroundCurrent: theme.searchHitBackgroundCurrent,
        searchHitForeground: theme.searchHitForeground,
      );
    }
    return theme;
  }

  /// Dark terminal (Tokyo Night / Warp-like). Colors are literal so this stays
  /// a compile-time constant independent of the chrome palette.
  static const TerminalTheme warp = TerminalTheme(
    cursor: Color(0xFFECE7DD),
    selection: Color(0x33ECE7DD),
    foreground: Color(0xFFECE7DD),
    background: Color(0xFF0A0A0A),
    black: Color(0xFF15161E),
    red: Color(0xFFF7768E),
    green: Color(0xFF9ECE6A),
    yellow: Color(0xFFE0AF68),
    blue: Color(0xFF7AA2F7),
    magenta: Color(0xFFBB9AF7),
    cyan: Color(0xFF7DCFFF),
    white: Color(0xFFA9B1D6),
    brightBlack: Color(0xFF565F89),
    brightRed: Color(0xFFFF8B9C),
    brightGreen: Color(0xFFB9F27C),
    brightYellow: Color(0xFFF2C26B),
    brightBlue: Color(0xFF9CB8FF),
    brightMagenta: Color(0xFFD2B8FF),
    brightCyan: Color(0xFFA2E3FF),
    brightWhite: Color(0xFFECE7DD),
    searchHitBackground: Color(0xFFE0AF68),
    searchHitBackgroundCurrent: Color(0xFFECE7DD),
    searchHitForeground: Color(0xFF0A0A0A),
  );

  /// True-black terminal for the OLED chrome: identical to [warp] but with a
  /// pure #000000 background so the terminal blends into the unlit panel.
  static const TerminalTheme oled = TerminalTheme(
    cursor: Color(0xFFECE7DD),
    selection: Color(0x33ECE7DD),
    foreground: Color(0xFFECE7DD),
    background: Color(0xFF000000),
    black: Color(0xFF000000),
    red: Color(0xFFF7768E),
    green: Color(0xFF9ECE6A),
    yellow: Color(0xFFE0AF68),
    blue: Color(0xFF7AA2F7),
    magenta: Color(0xFFBB9AF7),
    cyan: Color(0xFF7DCFFF),
    white: Color(0xFFA9B1D6),
    brightBlack: Color(0xFF565F89),
    brightRed: Color(0xFFFF8B9C),
    brightGreen: Color(0xFFB9F27C),
    brightYellow: Color(0xFFF2C26B),
    brightBlue: Color(0xFF9CB8FF),
    brightMagenta: Color(0xFFD2B8FF),
    brightCyan: Color(0xFFA2E3FF),
    brightWhite: Color(0xFFECE7DD),
    searchHitBackground: Color(0xFFE0AF68),
    searchHitBackgroundCurrent: Color(0xFFECE7DD),
    searchHitForeground: Color(0xFF000000),
  );

  /// Dracula (draculatheme.com).
  static const TerminalTheme dracula = TerminalTheme(
    cursor: Color(0xFFF8F8F2),
    selection: Color(0x6644475A),
    foreground: Color(0xFFF8F8F2),
    background: Color(0xFF282A36),
    black: Color(0xFF21222C),
    red: Color(0xFFFF5555),
    green: Color(0xFF50FA7B),
    yellow: Color(0xFFF1FA8C),
    blue: Color(0xFFBD93F9),
    magenta: Color(0xFFFF79C6),
    cyan: Color(0xFF8BE9FD),
    white: Color(0xFFF8F8F2),
    brightBlack: Color(0xFF6272A4),
    brightRed: Color(0xFFFF6E6E),
    brightGreen: Color(0xFF69FF94),
    brightYellow: Color(0xFFFFFFA5),
    brightBlue: Color(0xFFD6ACFF),
    brightMagenta: Color(0xFFFF92DF),
    brightCyan: Color(0xFFA4FFFF),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFF1FA8C),
    searchHitBackgroundCurrent: Color(0xFFF8F8F2),
    searchHitForeground: Color(0xFF282A36),
  );

  /// Gruvbox Dark (github.com/morhetz/gruvbox).
  static const TerminalTheme gruvbox = TerminalTheme(
    cursor: Color(0xFFEBDBB2),
    selection: Color(0x44EBDBB2),
    foreground: Color(0xFFEBDBB2),
    background: Color(0xFF282828),
    black: Color(0xFF282828),
    red: Color(0xFFCC241D),
    green: Color(0xFF98971A),
    yellow: Color(0xFFD79921),
    blue: Color(0xFF458588),
    magenta: Color(0xFFB16286),
    cyan: Color(0xFF689D6A),
    white: Color(0xFFA89984),
    brightBlack: Color(0xFF928374),
    brightRed: Color(0xFFFB4934),
    brightGreen: Color(0xFFB8BB26),
    brightYellow: Color(0xFFFABD2F),
    brightBlue: Color(0xFF83A598),
    brightMagenta: Color(0xFFD3869B),
    brightCyan: Color(0xFF8EC07C),
    brightWhite: Color(0xFFEBDBB2),
    searchHitBackground: Color(0xFFD79921),
    searchHitBackgroundCurrent: Color(0xFFEBDBB2),
    searchHitForeground: Color(0xFF282828),
  );

  /// Nord (nordtheme.com).
  static const TerminalTheme nord = TerminalTheme(
    cursor: Color(0xFFD8DEE9),
    selection: Color(0x554C566A),
    foreground: Color(0xFFD8DEE9),
    background: Color(0xFF2E3440),
    black: Color(0xFF3B4252),
    red: Color(0xFFBF616A),
    green: Color(0xFFA3BE8C),
    yellow: Color(0xFFEBCB8B),
    blue: Color(0xFF81A1C1),
    magenta: Color(0xFFB48EAD),
    cyan: Color(0xFF88C0D0),
    white: Color(0xFFE5E9F0),
    brightBlack: Color(0xFF4C566A),
    brightRed: Color(0xFFBF616A),
    brightGreen: Color(0xFFA3BE8C),
    brightYellow: Color(0xFFEBCB8B),
    brightBlue: Color(0xFF81A1C1),
    brightMagenta: Color(0xFFB48EAD),
    brightCyan: Color(0xFF8FBCBB),
    brightWhite: Color(0xFFECEFF4),
    searchHitBackground: Color(0xFFEBCB8B),
    searchHitBackgroundCurrent: Color(0xFFD8DEE9),
    searchHitForeground: Color(0xFF2E3440),
  );

  /// Light terminal (paper background, ink text, darkened ANSI palette tuned
  /// for contrast on a light surface).
  static const TerminalTheme paper = TerminalTheme(
    cursor: Color(0xFF1A1916),
    selection: Color(0x221A1916),
    foreground: Color(0xFF24231F),
    background: Color(0xFFF4F1EA),
    black: Color(0xFF2C2B27),
    red: Color(0xFFC0392B),
    green: Color(0xFF4F7A28),
    yellow: Color(0xFF9A6A12),
    blue: Color(0xFF2E5BB8),
    magenta: Color(0xFF7E4BB0),
    cyan: Color(0xFF227D93),
    white: Color(0xFF5C5950),
    brightBlack: Color(0xFF6E6A61),
    brightRed: Color(0xFFD0493B),
    brightGreen: Color(0xFF5E8C32),
    brightYellow: Color(0xFFB07C1E),
    brightBlue: Color(0xFF3A6BCB),
    brightMagenta: Color(0xFF8E5BC0),
    brightCyan: Color(0xFF2C8EA6),
    brightWhite: Color(0xFF1A1916),
    searchHitBackground: Color(0xFFE0AF68),
    searchHitBackgroundCurrent: Color(0xFF1A1916),
    searchHitForeground: Color(0xFFF4F1EA),
  );
}

class AppTheme {
  AppTheme._();

  /// Builds the Material [ThemeData] for [choice]. [platformBrightness]
  /// resolves the `system` option. Also calls [AppColors.apply] so the static
  /// palette and the returned theme stay in sync no matter the call order.
  static ThemeData themeFor(
      AppThemeChoice choice, Brightness platformBrightness, {String? accentColorHex}) {
    AppColors.apply(choice, platformBrightness, accentColorHex: accentColorHex);
    final brightness = AppColors.brightness;
    const radius = BorderRadius.zero; // Swiss precision: sharp corners
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: AppColors.ink,
      canvasColor: AppColors.ink,
      primaryColor: AppColors.accent,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: AppColors.accent,
        onPrimary: AppColors.ink,
        secondary: AppColors.muted,
        onSecondary: AppColors.ink,
        surface: AppColors.panel,
        onSurface: AppColors.bone,
        error: AppColors.danger,
        onError: AppColors.bone,
      ),
      textTheme: GoogleFonts.archivoTextTheme(
        ThemeData(brightness: brightness).textTheme,
      ).apply(bodyColor: AppColors.bone, displayColor: AppColors.bone),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: AppColors.hairline, width: 1),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: AppColors.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: AppColors.hairline, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.ink,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        labelStyle: AppText.label(10, color: AppColors.muted, spacing: 0.8),
        floatingLabelStyle:
            AppText.label(10, color: AppColors.accent, spacing: 0.8),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: AppColors.hairline, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: AppColors.accent, width: 1),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.panelHi,
        contentTextStyle: AppText.mono(11, color: AppColors.bone),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: AppColors.hairline, width: 1),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      useMaterial3: true,
    );
  }

  /// Backwards-compatible dark theme accessor.
  static ThemeData get dark =>
      themeFor(AppThemeChoice.dark, Brightness.dark);
}
