import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'app_identity.dart';
import 'settings_state.dart';

const _kTheme = 'theme_mode';
const _kSpaceName = 'space_name';

SharedPreferences? _prefs;
bool _wired = false;

/// 启动时调用：从 SharedPreferences 载入所有设置，并注册「变化即保存」的监听。
Future<void> initPersistence() async {
  final prefs = _prefs = await SharedPreferences.getInstance();
  await AppIdentity.initialize(prefs);
  await prefs.remove('hotspot_ssid');
  await prefs.remove('hotspot_password');

  final themeName = prefs.getString(_kTheme);
  if (themeName != null) {
    themeModeNotifier.value = ThemeMode.values.firstWhere(
      (m) => m.name == themeName,
      orElse: () => ThemeMode.system,
    );
  }
  spaceName.value = prefs.getString(_kSpaceName) ?? '';

  if (!_wired) {
    _wired = true;
    themeModeNotifier.addListener(() {
      _prefs?.setString(_kTheme, themeModeNotifier.value.name);
    });
    spaceName.addListener(() {
      _prefs?.setString(_kSpaceName, spaceName.value);
    });
  }
}
