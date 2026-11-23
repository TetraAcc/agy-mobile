import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ComposerPrefs {
  static const String queueModeQueue = 'queue';
  static const String queueModeImmediate = 'immediate';
  static const String sendKeyEnter = 'enter';
  static const String sendKeyCtrlEnter = 'ctrl_enter';

  final String queueMode;
  final String sendKey;

  const ComposerPrefs({
    this.queueMode = queueModeQueue,
    this.sendKey = sendKeyEnter,
  });

  bool get isQueueEnabled => queueMode != queueModeImmediate;
  bool get isCtrlEnterToSend => sendKey == sendKeyCtrlEnter;

  ComposerPrefs copyWith({
    String? queueMode,
    String? sendKey,
  }) {
    return ComposerPrefs(
      queueMode: queueMode ?? this.queueMode,
      sendKey: sendKey ?? this.sendKey,
    );
  }
}

class ComposerPrefsController extends Notifier<ComposerPrefs> {
  static const _queueModeKey = 'v2_composer_queue_mode';
  static const _sendKeyKey = 'v2_composer_send_key';

  @override
  ComposerPrefs build() {
    _loadPrefs();
    return const ComposerPrefs();
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final qMode = prefs.getString(_queueModeKey);
      final sKey = prefs.getString(_sendKeyKey);
      state = ComposerPrefs(
        queueMode: (qMode == ComposerPrefs.queueModeImmediate)
            ? ComposerPrefs.queueModeImmediate
            : ComposerPrefs.queueModeQueue,
        sendKey: (sKey == ComposerPrefs.sendKeyCtrlEnter)
            ? ComposerPrefs.sendKeyCtrlEnter
            : ComposerPrefs.sendKeyEnter,
      );
    } catch (_) {}
  }

  Future<void> setQueueMode(String mode) async {
    final normalized = (mode == ComposerPrefs.queueModeImmediate)
        ? ComposerPrefs.queueModeImmediate
        : ComposerPrefs.queueModeQueue;
    state = state.copyWith(queueMode: normalized);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_queueModeKey, normalized);
    } catch (_) {}
  }

  Future<void> setSendKey(String sendKey) async {
    final normalized = (sendKey == ComposerPrefs.sendKeyCtrlEnter)
        ? ComposerPrefs.sendKeyCtrlEnter
        : ComposerPrefs.sendKeyEnter;
    state = state.copyWith(sendKey: normalized);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sendKeyKey, normalized);
    } catch (_) {}
  }
}

final composerPrefsProvider = NotifierProvider<ComposerPrefsController, ComposerPrefs>(
  ComposerPrefsController.new,
);
