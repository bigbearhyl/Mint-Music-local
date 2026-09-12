import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局 AMLL 歌词引擎开关（单例）
///
/// 使用 [ChangeNotifier] 而非 Riverpod 的 [StateProvider]，
/// 避免在特定路由/作用域下 Provider 值不同步的问题。
///
/// [LyricPage] 和设置页通过 [addListener] / [ListenableBuilder] 共享同一实例，
/// 保证开关值的实时同步。
class AmllToggleService extends ChangeNotifier {
  // ---- 单例 ----
  static final AmllToggleService _instance = AmllToggleService._();
  factory AmllToggleService() => _instance;
  AmllToggleService._();

  /// 2026-09-12：默认改用 Flutter 逐字歌词（未唱白 / 已唱绿）。
  /// AMLL 是单色 + 遮罩透明度实现，做不到双色逐字，故默认关闭；
  /// 键名升级为 v2，忽略旧版本默认写入的 true。
  static const String _prefsKey = 'amll_lyric_enabled_v2';

  bool _enabled = false;
  SharedPreferences? _prefs;

  /// 当前是否启用了 AMLL 歌词引擎
  bool get enabled => _enabled;

  /// 设置开关值（立即通知监听者）
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
  }

  /// 从 SharedPreferences 初始化（用于启动时）
  Future<void> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      _enabled = prefs.getBool(_prefsKey) ?? false;
      notifyListeners();
      debugPrint('[AmllToggle] loaded: $_enabled');
    } catch (e) {
      debugPrint('[AmllToggle] load error: $e');
    }
  }

  /// 持久化到 SharedPreferences
  Future<void> saveToPrefs() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, _enabled);
      debugPrint('[AmllToggle] saved: $_enabled');
    } catch (e) {
      debugPrint('[AmllToggle] save error: $e');
    }
  }

  /// 切换并持久化（方便外部调用）
  Future<void> setAndPersist(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    await saveToPrefs();
  }
}
