import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本机安装身份只用于局域网请求，不写入日志或公开文件列表。
class AppIdentity {
  static const header = 'X-LinkNest-Identity';
  static const preferenceKey = 'app_installation_identity';
  static final validId = RegExp(r'^[a-f0-9]{64}$');
  static String _id = '';
  static String get id => _id;

  static Future<void> initialize(SharedPreferences preferences) async {
    final saved = preferences.getString(preferenceKey);
    if (saved != null && validId.hasMatch(saved)) {
      _id = saved;
      debugPrint('[LinkNest] 已恢复本机上传身份');
      return;
    }
    final random = Random.secure();
    final created = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    if (!await preferences.setString(preferenceKey, created)) {
      throw StateError('无法保存本机上传身份');
    }
    _id = created;
    debugPrint('[LinkNest] 已创建并保存本机上传身份');
  }

  /// 公开的上传者标识限定在当前空间，不能反推出安装身份。
  static String forSpace(String spaceId, String installationId) =>
      installationId.isEmpty
      ? ''
      : sha256.convert(utf8.encode('$spaceId:$installationId')).toString();
}
