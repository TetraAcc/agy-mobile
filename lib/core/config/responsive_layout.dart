import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Unified responsive layout breakpoints for phones, Android tablets
/// (e.g. Lenovo Xiaoxin Pad Pro 12.7" in landscape/portrait/split-screen),
/// foldables, and desktop web.
class ResponsiveLayout {
  static const double tabletBreakpoint = 600.0;
  static const double wideSidebarBreakpoint = 900.0;
  static const double permanentSidebarWidth = 296.0;

  static double screenWidth(BuildContext context) => MediaQuery.sizeOf(context).width;

  static double screenHeight(BuildContext context) => MediaQuery.sizeOf(context).height;

  static bool isTabletOrLarger(BuildContext context) =>
      screenWidth(context) >= tabletBreakpoint;

  static bool usePermanentSidebar(BuildContext context) =>
      screenWidth(context) >= wideSidebarBreakpoint;

  /// Optimal centered reading & composer column width.
  static double contentMaxWidth(BuildContext context) {
    final width = screenWidth(context);
    if (width >= tabletBreakpoint) return 840.0;
    return 780.0;
  }

  /// AppBar node badge text max width (wider on tablets so full host names fit).
  static double nodeBadgeMaxWidth(BuildContext context) {
    return isTabletOrLarger(context) ? 180.0 : 88.0;
  }

  /// Wide bottom sheet constraints for code diff review, file viewer/editor,
  /// workspace browser, artifacts, and tool outputs.
  /// Overrides Material 3's default 640dp BottomSheet maxWidth cap on tablets.
  static BoxConstraints workspaceSheetConstraints(BuildContext context) {
    final width = screenWidth(context);
    if (width < tabletBreakpoint) {
      return BoxConstraints(maxWidth: width);
    }
    final maxW = math.min(width * 0.92, 1080.0);
    return BoxConstraints(maxWidth: maxW);
  }

  /// Compact centered bottom sheet constraints for action menus on tablets.
  static BoxConstraints compactSheetConstraints(BuildContext context) {
    final width = screenWidth(context);
    if (width < tabletBreakpoint) {
      return BoxConstraints(maxWidth: width);
    }
    return BoxConstraints(maxWidth: math.min(width * 0.85, 520.0));
  }

  /// Detects compact viewport height when on-screen keyboard opens in landscape.
  static bool isCompactHeightKeyboardOpen(BuildContext context) {
    return MediaQuery.viewInsetsOf(context).bottom > 100.0 &&
        screenHeight(context) < 620.0;
  }
}
