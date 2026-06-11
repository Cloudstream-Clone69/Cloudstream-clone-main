// lib/shared/theme/app_theme.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const background = Color(0xFF0A0A0F);
  static const surface = Color(0xFF141419);
  static const surfaceHigh = Color(0xFF1E1E26);
  static const surfaceHigher = Color(0xFF252530);
  static const accent = Color(0xFFE50914);
  static const accentDim = Color(0xFF9B0610);
  static const primary = Color(0xFFFFFFFF);
  static const secondary = Color(0xFFB3B3B3);
  static const tertiary = Color(0xFF6B6B7A);
  static const sidebarBg = Color(0xFF0D0D12);
  static const cardBorder = Color(0xFF2A2A35);
  static const shimmerBase = Color(0xFF1E1E26);
  static const shimmerHighlight = Color(0xFF2E2E3A);
}

class AppTheme {
  static ThemeData get dark {
    final base = ThemeData.dark();
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: const ColorScheme.dark(
        surface: AppColors.surface,
        primary: AppColors.accent,
        onPrimary: Colors.white,
        secondary: AppColors.secondary,
        onSurface: AppColors.primary,
        error: Color(0xFFCF6679),
      ),
      textTheme: GoogleFonts.interTextTheme(base.textTheme).copyWith(
        displayLarge: GoogleFonts.inter(
          fontSize: 48,
          fontWeight: FontWeight.w800,
          color: AppColors.primary,
          letterSpacing: -1.5,
        ),
        displayMedium: GoogleFonts.inter(
          fontSize: 36,
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
          letterSpacing: -1,
        ),
        headlineLarge: GoogleFonts.inter(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
          letterSpacing: -0.5,
        ),
        headlineMedium: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.primary,
        ),
        titleLarge: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AppColors.primary,
        ),
        titleMedium: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: AppColors.secondary,
        ),
        bodyLarge: GoogleFonts.inter(
          fontSize: 14,
          color: AppColors.secondary,
          height: 1.6,
        ),
        bodyMedium: GoogleFonts.inter(
          fontSize: 13,
          color: AppColors.tertiary,
        ),
        labelLarge: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.primary,
          letterSpacing: 0.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppColors.cardBorder, width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 14),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(AppColors.surfaceHigher),
        trackColor: WidgetStateProperty.all(Colors.transparent),
        radius: const Radius.circular(4),
        thickness: WidgetStateProperty.all(4),
      ),
    );
  }
}
