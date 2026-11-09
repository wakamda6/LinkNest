import 'dart:async';

import 'package:flutter/services.dart';

bool isLikelyWifiInterface(String value) {
  final name = value.toLowerCase();
  return name.startsWith('en') ||
      name.contains('wlan') ||
      name.contains('wifi');
}

enum NativeSaveStatus {
  saved,
  partial,
  cancelled,
  permissionDenied,
  unsupported,
  failed,
}

class NativeSaveResult {
  const NativeSaveResult({
    required this.status,
    this.message = '',
    this.savedCount = 0,
  });

  factory NativeSaveResult.fromChannel(dynamic value) {
    if (value is bool) {
      return NativeSaveResult(
        status: value ? NativeSaveStatus.saved : NativeSaveStatus.failed,
        savedCount: value ? 1 : 0,
      );
    }
    final map = value is Map ? value : const <dynamic, dynamic>{};
    final status = switch (map['status']?.toString()) {
      'saved' => NativeSaveStatus.saved,
      'partial' => NativeSaveStatus.partial,
      'cancelled' => NativeSaveStatus.cancelled,
      'permissionDenied' => NativeSaveStatus.permissionDenied,
      'unsupported' => NativeSaveStatus.unsupported,
      _ => NativeSaveStatus.failed,
    };
    return NativeSaveResult(
      status: status,
      message: map['message']?.toString() ?? '',
      savedCount:
          (map['savedCount'] as num?)?.toInt() ??
          (status == NativeSaveStatus.saved ? 1 : 0),
    );
  }

  final NativeSaveStatus status;
  final String message;
  final int savedCount;

  bool get succeeded => status == NativeSaveStatus.saved;
  bool get cancelled => status == NativeSaveStatus.cancelled;
}

class NativeSaveFile {
  const NativeSaveFile({
    required this.path,
    required this.name,
    required this.mimeType,
  });

  final String path;
  final String name;
  final String mimeType;

  Map<String, String> toMap() => {
    'path': path,
    'name': name,
    'mimeType': mimeType,
  };
}

class DevicePowerState {
  const DevicePowerState({
    required this.level,
    required this.charging,
    required this.lowPowerMode,
  });

  factory DevicePowerState.fromMap(Map<String, dynamic> value) {
    final rawLevel = value['level'];
    final level = rawLevel is num && rawLevel >= 0 && rawLevel <= 1
        ? rawLevel.toDouble()
        : null;
    return DevicePowerState(
      level: level,
      charging: value['charging'] == true,
      lowPowerMode: value['lowPowerMode'] == true,
    );
  }

  final double? level;
  final bool charging;
  final bool lowPowerMode;
}

class NativePhotoCoordinates {
  const NativePhotoCoordinates(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

class NativeHotspotState {
  const NativeHotspotState({
    required this.state,
    required this.unexpected,
    this.reason,
  });

  factory NativeHotspotState.fromMap(Map<String, dynamic> value) =>
      NativeHotspotState(
        state: value['state']?.toString() ?? 'unknown',
        unexpected: value['unexpected'] == true,
        reason: (value['reason'] as num?)?.toInt(),
      );

  final String state;
  final bool unexpected;
  final int? reason;
}

/// 原生平台通道封装：热点、本机 IP、保持唤醒、缩略图。
///
/// 通道名 `linknest/native`，由 Android `MainActivity` 与 iOS `AppDelegate`
/// 各自实现（M0 阶段）。
class LinkNestNative {
  static const MethodChannel _channel = MethodChannel('linknest/native');
  static final StreamController<void> _guestBackgroundTimeExpiredController =
      StreamController<void>.broadcast(sync: true);
  static final StreamController<NativeHotspotState> _hotspotStateController =
      StreamController<NativeHotspotState>.broadcast(sync: true);
  static bool _methodHandlerInstalled = false;
  static final _guestWifiController =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  void _ensureMethodHandler() {
    if (_methodHandlerInstalled) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'guestWifiChanged':
          _guestWifiController.add(_asMap(call.arguments));
        case 'guestBackgroundTimeExpired':
          _guestBackgroundTimeExpiredController.add(null);
        case 'hotspotStateChanged':
          _hotspotStateController.add(
            NativeHotspotState.fromMap(_asMap(call.arguments)),
          );
      }
    });
    _methodHandlerInstalled = true;
  }

  Stream<void> get guestBackgroundTimeExpired {
    _ensureMethodHandler();
    return _guestBackgroundTimeExpiredController.stream;
  }

  Stream<Map<String, dynamic>> get guestWifiChanges {
    _ensureMethodHandler();
    return _guestWifiController.stream;
  }

  Future<String> joinGuestWifi({
    required int requestId,
    required String ssid,
    required String password,
    required String security,
    required bool hidden,
  }) async {
    final result = _asMap(
      await _channel.invokeMethod('joinGuestWifi', {
        'requestId': requestId,
        'ssid': ssid,
        'password': password,
        'security': security,
        'hidden': hidden,
      }),
    );
    return result['status']?.toString() ?? 'failed';
  }

  Future<void> releaseGuestWifi(int requestId) =>
      _channel.invokeMethod('releaseGuestWifi', {'requestId': requestId});

  /// iOS 没有公开的 Wi-Fi 设置直达地址，返回 false 后在 App 显示手动指引。
  Future<bool> openWifiSettings() async =>
      await _channel.invokeMethod<bool>('openWifiSettings') ?? false;

  Stream<NativeHotspotState> get hotspotStateChanges {
    _ensureMethodHandler();
    return _hotspotStateController.stream;
  }

  /// 获取本机局域网 IP（热点网关）。
  Future<String> getLocalIp() async {
    final r = await _channel.invokeMethod<String>('getLocalIp');
    return r ?? '';
  }

  /// 热点状态信息。
  Future<Map<String, dynamic>> getHotspotInfo() async {
    return _asMap(await _channel.invokeMethod('getHotspotInfo'));
  }

  /// 启动临时热点。
  /// Android：`startLocalOnlyHotspot`，返回 {supported, ssid, password}。
  /// iOS：无公开 API，返回 {supported: false, message: 引导文案}。
  Future<Map<String, dynamic>> startHotspot() async {
    return _asMap(await _channel.invokeMethod('startHotspot'));
  }

  /// 停止热点（Android 关闭 LocalOnlyHotspot；iOS 为无操作）。
  Future<void> stopHotspot() async {
    await _channel.invokeMethod('stopHotspot');
  }

  Future<String> getCurrentWifiSsid() async =>
      await _channel.invokeMethod<String>('getCurrentWifiSsid') ?? '';

  /// 保持屏幕常亮。
  Future<void> setKeepAwake(bool enabled) async {
    await _channel.invokeMethod('setKeepAwake', {'enabled': enabled});
  }

  /// Android Host 共享期间以前台 Service 提升进程优先级。
  /// 返回通知权限是否可用；权限被拒绝不等于 Service 启动失败。
  Future<bool> startHostForegroundService({
    required String spaceName,
    required int onlineCount,
  }) async {
    final result = _asMap(
      await _channel.invokeMethod('startHostForegroundService', {
        'spaceName': spaceName,
        'onlineCount': onlineCount,
      }),
    );
    return result['notificationPermissionGranted'] == true;
  }

  Future<void> updateHostForegroundService({
    required String spaceName,
    required int onlineCount,
  }) async {
    await _channel.invokeMethod('updateHostForegroundService', {
      'spaceName': spaceName,
      'onlineCount': onlineCount,
    });
  }

  Future<void> stopHostForegroundService() async {
    await _channel.invokeMethod('stopHostForegroundService');
  }

  /// Android 使用 connectedDevice 前台服务；iOS 申请有限后台执行时间。
  Future<bool> startGuestTransferService({
    required String direction,
    required String fileName,
    required int totalBytes,
  }) async {
    final result = _asMap(
      await _channel.invokeMethod('startGuestTransferService', {
        'direction': direction,
        'fileName': fileName,
        'totalBytes': totalBytes,
      }),
    );
    return result['started'] == true;
  }

  Future<void> updateGuestTransferService({
    required String direction,
    required String fileName,
    required int completedBytes,
    required int totalBytes,
  }) async {
    await _channel.invokeMethod('updateGuestTransferService', {
      'direction': direction,
      'fileName': fileName,
      'completedBytes': completedBytes,
      'totalBytes': totalBytes,
    });
  }

  Future<void> stopGuestTransferService() async {
    await _channel.invokeMethod('stopGuestTransferService');
  }

  /// 电量比例、是否接电和系统低电量模式。无法取得比例时 level 为 null。
  Future<DevicePowerState> getPowerState() async {
    final result = _asMap(await _channel.invokeMethod('getPowerState'));
    return DevicePowerState.fromMap(result);
  }

  /// 获取可用于访客连接的本机私网 IPv4，按平台判断的可靠性降序排列。
  Future<List<Map<String, dynamic>>> getLocalAddresses({
    bool diagnostic = false,
  }) async {
    final result = await _channel.invokeMethod('getLocalAddresses', {
      if (diagnostic) 'diagnostic': true,
    });
    if (result is! List) return const [];
    return result.whereType<Map>().map(_asMap).toList();
  }

  /// Android 原生 NSD 查找所有当前可解析的空间；iOS 使用 Bonjour 插件。
  Future<List<Map<String, dynamic>>> discoverSpaces({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final result = await _channel.invokeMethod('discoverSpaces', {
      'timeoutMs': timeout.inMilliseconds,
    });
    if (result is! List) return const [];
    return result.whereType<Map>().map(_asMap).toList();
  }

  Future<void> startSpaceAdvertisement(Map<String, dynamic> attributes) async {
    await _channel.invokeMethod('startSpaceAdvertisement', attributes);
  }

  Future<void> stopSpaceAdvertisement() async {
    await _channel.invokeMethod('stopSpaceAdvertisement');
  }

  /// 当前 Wi-Fi 的网关候选，只返回私网 IPv4；用于 Guest 在 Host 地址变化后重连。
  Future<List<String>> getWifiGatewayCandidates() async {
    final result = await _channel.invokeMethod('getWifiGatewayCandidates');
    if (result is! List) return const [];
    return result
        .map((value) => value?.toString() ?? '')
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  /// 应用数据卷可用于重要写入的剩余字节数；无法查询时返回 -1。
  Future<int> getFreeDiskBytes() async {
    final r = await _channel.invokeMethod<num>('getFreeDiskBytes');
    return r?.toInt() ?? -1;
  }

  /// 为 iOS 本地播放器创建带扩展名的同卷硬链接，不复制原视频字节。
  Future<String> prepareLocalVideoPlayback(
    String sourcePath,
    String extension,
  ) async {
    final path = await _channel.invokeMethod<String>(
      'prepareLocalVideoPlayback',
      {'path': sourcePath, 'extension': extension},
    );
    if (path == null || path.isEmpty) {
      throw PlatformException(
        code: 'VIDEO_LINK_FAILED',
        message: '无法准备本地视频播放文件',
      );
    }
    return path;
  }

  /// Host App 的用户可见版本号。
  Future<String> getAppVersion() async {
    final r = await _channel.invokeMethod<String>('getAppVersion');
    return r ?? 'unknown';
  }

  /// 生成缩略图（JPEG 字节）。`kind` 区分 image/video/other，`target` 为长边最大像素（网格 512，大图预览更高），
  /// `name` 为原始文件名（视频取帧需靠扩展名识别容器，原文件无扩展名）。
  Future<Uint8List> makeThumbnail(
    String filePath, {
    String kind = '',
    int target = 512,
    String name = '',
  }) async {
    final r = await _channel.invokeMethod<Uint8List>('makeThumbnail', {
      'path': filePath,
      'kind': kind,
      'target': target,
      'name': name,
    });
    return r ?? Uint8List(0);
  }

  /// 读取照片文件中的 GPS；不读取设备当前位置，也不记录坐标日志。
  Future<NativePhotoCoordinates?> readPhotoCoordinates(String filePath) async {
    final value = _asMap(
      await _channel.invokeMethod('readPhotoCoordinates', {'path': filePath}),
    );
    final latitude = value['latitude'];
    final longitude = value['longitude'];
    if (latitude is! num || longitude is! num) return null;
    return NativePhotoCoordinates(latitude.toDouble(), longitude.toDouble());
  }

  /// 使用系统服务反向地理编码，返回从省/州开始的简短地点标签。
  Future<String?> reverseGeocode(double latitude, double longitude) async {
    final value = await _channel.invokeMethod<String>('reverseGeocode', {
      'latitude': latitude,
      'longitude': longitude,
    });
    final label = value?.trim() ?? '';
    return label.isEmpty ? null : label;
  }

  /// 从相册选择媒体（图片/视频），拷贝进应用缓存目录。
  /// 返回照片路径、名称及可选的 Live Photo 配对视频路径、名称。
  /// 空列表 = 用户取消或未选。
  Future<List<Map<String, String>>> pickFromAlbum() async {
    final r = await _channel.invokeMethod('pickFromAlbum');
    if (r is! List) return const [];
    return r
        .whereType<Map>()
        .map((m) {
          final path = m['path']?.toString() ?? '';
          final name = m['name']?.toString() ?? '';
          return {
            'path': path,
            'name': name,
            'pairedVideoPath': m['pairedVideoPath']?.toString() ?? '',
            'pairedVideoName': m['pairedVideoName']?.toString() ?? '',
          };
        })
        .where((m) => m['path']!.isNotEmpty)
        .toList();
  }

  /// 保存文件到系统相册（图片/视频）。`fileName` 为原始文件名（含扩展名，用于判类型与相册命名）。
  Future<NativeSaveResult> saveToAlbum(
    String filePath,
    String fileName, {
    String kind = '',
    String mimeType = 'application/octet-stream',
  }) async {
    final r = await _channel.invokeMethod('saveToAlbum', {
      'path': filePath,
      'name': fileName,
      'kind': kind,
      'mimeType': mimeType,
    });
    return NativeSaveResult.fromChannel(r);
  }

  Future<NativeSaveResult> saveLivePhoto({
    required String photoPath,
    required String photoName,
    required String pairedVideoPath,
    required String pairedVideoName,
  }) async {
    final r = await _channel.invokeMethod('saveLivePhoto', {
      'photoPath': photoPath,
      'photoName': photoName,
      'pairedVideoPath': pairedVideoPath,
      'pairedVideoName': pairedVideoName,
    });
    return NativeSaveResult.fromChannel(r);
  }

  Future<NativeSaveResult> saveToFiles(List<NativeSaveFile> files) async {
    if (files.isEmpty) {
      return const NativeSaveResult(
        status: NativeSaveStatus.failed,
        message: '没有可保存的文件',
      );
    }
    final r = await _channel.invokeMethod('saveToFiles', {
      'files': files.map((file) => file.toMap()).toList(),
    });
    return NativeSaveResult.fromChannel(r);
  }

  static Map<String, dynamic> _asMap(dynamic v) {
    if (v is Map) {
      return v.map((k, val) => MapEntry(k.toString(), val));
    }
    return {};
  }
}
