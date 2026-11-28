import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SidebarGroupBy {
  project,
  activity;

  String get storageValue => name;

  static SidebarGroupBy fromStorage(String? raw) {
    if (raw == SidebarGroupBy.activity.name) {
      return SidebarGroupBy.activity;
    }
    return SidebarGroupBy.project;
  }
}

class SidebarPrefsController extends Notifier<SidebarGroupBy> {
  static const String _groupByKey = 'v2_sidebar_group_by';

  @override
  SidebarGroupBy build() {
    _loadPrefs();
    return SidebarGroupBy.project;
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final next = SidebarGroupBy.fromStorage(prefs.getString(_groupByKey));
      if (state != next) {
        state = next;
      }
    } catch (_) {}
  }

  Future<void> setGroupBy(SidebarGroupBy mode) async {
    if (state != mode) {
      state = mode;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_groupByKey, mode.storageValue);
    } catch (_) {}
  }
}

final sidebarPrefsProvider = NotifierProvider<SidebarPrefsController, SidebarGroupBy>(
  SidebarPrefsController.new,
);
