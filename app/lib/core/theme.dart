import 'package:flutter/material.dart';

/// Calm, data-first palette ("Soft cards"). Metric accents are shared by
/// cards and charts; use [MetricColors.of] so dark mode gets its own shades.
class AppColors {
  static const seed = Color(0xFF2F6F62);
  static const sleep = Color(0xFF4F5BC4);
  static const heart = Color(0xFFC2534D);
  static const activity = Color(0xFF2A7F57);
  static const points = Color(0xFFE0A030);
}

/// Corner radii and spacing used across screens.
class AppRadius {
  static const card = 20.0;
  static const inset = 14.0;
  static const field = 26.0;
}

class AppSpace {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 20.0;
  static const xxl = 28.0;
  /// Side padding of every screen.
  static const page = EdgeInsets.fromLTRB(20, 8, 20, 24);
}

/// Metric accent colours with a light tint for bands and icon chips.
@immutable
class MetricColors extends ThemeExtension<MetricColors> {
  const MetricColors({
    required this.sleep,
    required this.sleepTint,
    required this.heart,
    required this.heartTint,
    required this.activity,
    required this.activityTint,
  });
  final Color sleep, sleepTint, heart, heartTint, activity, activityTint;

  static const light = MetricColors(
    sleep: AppColors.sleep,
    sleepTint: Color(0xFFEEF0FB),
    heart: AppColors.heart,
    heartTint: Color(0xFFFBEEEC),
    activity: AppColors.activity,
    activityTint: Color(0xFFE8F4EE),
  );

  static const dark = MetricColors(
    sleep: Color(0xFF9AA4F2),
    sleepTint: Color(0xFF2A2F52),
    heart: Color(0xFFF09B96),
    heartTint: Color(0xFF45292A),
    activity: Color(0xFF7FD1A6),
    activityTint: Color(0xFF1F3A2E),
  );

  static MetricColors of(BuildContext context) =>
      Theme.of(context).extension<MetricColors>() ?? light;

  @override
  MetricColors copyWith({
    Color? sleep,
    Color? sleepTint,
    Color? heart,
    Color? heartTint,
    Color? activity,
    Color? activityTint,
  }) => MetricColors(
    sleep: sleep ?? this.sleep,
    sleepTint: sleepTint ?? this.sleepTint,
    heart: heart ?? this.heart,
    heartTint: heartTint ?? this.heartTint,
    activity: activity ?? this.activity,
    activityTint: activityTint ?? this.activityTint,
  );

  @override
  MetricColors lerp(MetricColors? other, double t) {
    if (other == null) return this;
    return MetricColors(
      sleep: Color.lerp(sleep, other.sleep, t)!,
      sleepTint: Color.lerp(sleepTint, other.sleepTint, t)!,
      heart: Color.lerp(heart, other.heart, t)!,
      heartTint: Color.lerp(heartTint, other.heartTint, t)!,
      activity: Color.lerp(activity, other.activity, t)!,
      activityTint: Color.lerp(activityTint, other.activityTint, t)!,
    );
  }
}

ColorScheme _scheme(Brightness brightness) {
  final base = ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: brightness,
  );
  if (brightness == Brightness.light) {
    return base.copyWith(
      primary: const Color(0xFF2F6F62),
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFE3EFEB),
      onPrimaryContainer: const Color(0xFF173A33),
      secondaryContainer: const Color(0xFFE3EFEB),
      onSecondaryContainer: const Color(0xFF173A33),
      surface: const Color(0xFFF6F7F5),
      onSurface: const Color(0xFF1A1D1B),
      onSurfaceVariant: const Color(0xFF5E6560),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Colors.white,
      surfaceContainer: const Color(0xFFF1F3F0),
      surfaceContainerHigh: const Color(0xFFE9ECE8),
      surfaceContainerHighest: const Color(0xFFE3E6E1),
      outline: const Color(0xFFDDE1DC),
      outlineVariant: const Color(0xFFE6E8E4),
      error: const Color(0xFFA8322C),
    );
  }
  return base.copyWith(
    primary: const Color(0xFF8FD3C0),
    onPrimary: const Color(0xFF0E2A24),
    primaryContainer: const Color(0xFF22302D),
    onPrimaryContainer: const Color(0xFFCDEDE4),
    secondaryContainer: const Color(0xFF22302D),
    onSecondaryContainer: const Color(0xFFCDEDE4),
    surface: const Color(0xFF101415),
    onSurface: const Color(0xFFE8ECEA),
    onSurfaceVariant: const Color(0xFFA0A9A5),
    surfaceContainerLowest: const Color(0xFF181D1F),
    surfaceContainerLow: const Color(0xFF181D1F),
    surfaceContainer: const Color(0xFF1C2224),
    surfaceContainerHigh: const Color(0xFF232A2C),
    surfaceContainerHighest: const Color(0xFF2A3133),
    outline: const Color(0xFF343B3D),
    outlineVariant: const Color(0xFF252B2D),
    error: const Color(0xFFF2B8B5),
  );
}

ThemeData buildTheme(Brightness brightness) {
  final scheme = _scheme(brightness);
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final text = base.textTheme.copyWith(
    headlineSmall: base.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w600, letterSpacing: -0.5, height: 1.2,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w600, letterSpacing: -0.2,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
  ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

  const stadium = StadiumBorder();
  final cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.card),
    side: BorderSide(color: scheme.outlineVariant),
  );
  final fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadius.field),
    borderSide: BorderSide(color: scheme.outline),
  );

  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    extensions: [
      brightness == Brightness.light ? MetricColors.light : MetricColors.dark,
    ],
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: cardShape,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 20,
      titleTextStyle: text.headlineSmall?.copyWith(fontSize: 24),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      elevation: 0,
      height: 72,
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
        size: 22,
        color: states.contains(WidgetState.selected)
            ? scheme.primary : scheme.onSurfaceVariant,
      )),
      labelTextStyle: WidgetStateProperty.resolveWith((states) =>
        text.labelMedium?.copyWith(
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600 : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface : scheme.onSurfaceVariant,
        )),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: stadium,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: text.labelLarge?.copyWith(fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: stadium,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        foregroundColor: scheme.onSurface,
        backgroundColor: scheme.surfaceContainerLowest,
        side: BorderSide(color: scheme.outline),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: stadium,
        minimumSize: const Size(0, 44),
        textStyle: text.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(stadium),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? scheme.primaryContainer : scheme.surfaceContainerLowest),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: StadiumBorder(side: BorderSide(color: scheme.outline)),
      side: BorderSide(color: scheme.outline),
      backgroundColor: scheme.surfaceContainerLowest,
      selectedColor: scheme.primaryContainer,
      showCheckmark: false,
      labelStyle: text.labelLarge?.copyWith(
        fontWeight: FontWeight.w500, color: scheme.onSurface,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      focusedBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minVerticalPadding: 10,
      subtitleTextStyle: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant, thickness: 1, space: 1,
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.inset)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.outlineVariant,
    ),
  );
}
