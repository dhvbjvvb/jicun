import 'package:flutter/material.dart';

/// 前景/次要文字色。一级列表与二级页共用同一套,两级观感才不会分家。
({Color foreground, Color secondary}) settingsPalette(bool isDark) => (
  foreground: isDark ? const Color(0xFFF5F7FA) : const Color(0xFF1B2430),
  secondary: isDark ? const Color(0xFFADB7C5) : const Color(0xFF6E7887),
);

