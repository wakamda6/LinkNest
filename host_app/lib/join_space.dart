import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'app_motion.dart';
import 'app_ui.dart';

import 'package:mobile_scanner/mobile_scanner.dart';

import 'guest_api_client.dart';
import 'guest_data_source.dart';
import 'guest_media_cache.dart';
import 'guest_transfer_runtime.dart';
import 'guest_space_history.dart';
import 'native.dart';
import 'space_discovery.dart';
import 'space_gallery.dart';
import 'space_invite.dart';
import 'wifi_join.dart';

class JoinSpaceScreen extends StatefulWidget {
  const JoinSpaceScreen({
    super.key,
    this.native,
    this.historySpace,
    this.initialSpace,
    this.clientFactory,
  });

  final LinkNestNative? native;
  final RecentGuestSpace? historySpace;
  final DiscoveredSpace? initialSpace;
  final GuestApiClient Function(SpaceInvite)? clientFactory;

  @override
  State<JoinSpaceScreen> createState() => _JoinSpaceScreenState();
}

class _JoinSpaceScreenState extends State<JoinSpaceScreen>
    with WidgetsBindingObserver {
  final TextEditingController _urlController = TextEditingController();
  late final LinkNestNative _native;
  late final GuestWifiController _wifi;
  final LinkNestDiscovery _discovery = const LinkNestDiscovery();
  final MobileScannerController _scannerController = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  GuestSpaceHistory? _history;
  bool _connecting = false;
  bool _discovering = false;
  bool _scanConsumed = false;
  bool? _wifiConnected;
  bool _wifiCheckInFlight = false;
  String? _errorMessage;
  String? _lastWifiCode;
  bool _foreground = true;
  bool _showScannerFallback = false;
  int _discoveryEpoch = 0;
  bool get _busy => _connecting || _wifi.connecting;
  bool get _historyOnly => widget.historySpace != null;
  bool get _useSystemCameraForWifi =>
      defaultTargetPlatform == TargetPlatform.iOS &&
      !iosHotspotConfigurationEnabled;

  @override
  void initState() {
    super.initState();
    _native = widget.native ?? LinkNestNative();
    _wifi = GuestWifiController(_native)..addListener(_wifiChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_historyOnly) {
        unawaited(_connectHistory());
      } else if (widget.initialSpace case final space?) {
        unawaited(
          _connectInvites(
            space.invites,
            expectedSpaceId: space.spaceId,
            expectedSessionId: space.sessionId,
          ),
        );
      } else {
        unawaited(_startScanner());
        unawaited(_initializeAndDiscover());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wifi.removeListener(_wifiChanged);
    _wifi.dispose();
    _urlController.dispose();
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshWifiState());
    } else {
      _discoveryEpoch++;
      unawaited(_stopScanner());
    }
  }

  void _wifiChanged() {
    if (!mounted) return;
    setState(() {
      if (_wifi.state == WifiJoinState.disconnected) _wifiConnected = false;
    });
  }

  Future<void> _connectWifi(WifiCredentials credentials) async {
    if (_busy || _useSystemCameraForWifi) return;
    _discoveryEpoch++;
    setState(() => _errorMessage = null);
    await _stopScanner();
    if (!mounted) return;
    await _wifi.connect(credentials);
    if (!mounted) return;
    await _refreshWifiState();
    await _startScanner();
  }

  Future<void> _manualWifi() async {
    if (_busy) return;
    _discoveryEpoch++;
    await _wifi.release();
    if (!mounted) return;
    try {
      if (await _native.openWifiSettings()) return;
    } catch (error) {
      debugPrint('[LinkNest] 打开 Wi-Fi 设置失败 reason=${error.runtimeType}');
    }
    if (!mounted) return;
    await showLinkNestDialog<void>(
      context: context,
      builder: (context) => LinkNestDialog(
        title: '手动连接 Wi-Fi',
        actions: [
          LinkNestButton(
            onPressed: () => popLinkNest(context),
            label: '知道了',
            variant: FButtonVariant.secondary,
          ),
        ],
        child: const Text(
          '请打开系统“设置 → Wi-Fi”，使用发起者显示的热点名称和密码连接，然后返回 LinkNest 扫描空间码。',
        ),
      ),
    );
  }

  Future<void> _showSystemCameraInstructions() async {
    if (_busy) return;
    await showLinkNestDialog<void>(
      context: context,
      builder: (context) => LinkNestDialog(
        title: '用系统相机连接热点',
        actions: [
          LinkNestButton(
            onPressed: () => popLinkNest(context),
            label: '知道了',
            variant: FButtonVariant.secondary,
          ),
        ],
        child: const Text(
          '请离开 LinkNest，打开 iPhone 系统相机扫描发起者的 Wi-Fi 码，按系统提示加入热点；返回 LinkNest 后扫描空间码。若相机无法识别，请在“设置 → Wi-Fi”中手动连接。',
        ),
      ),
    );
  }

  Future<void> _initializeAndDiscover() async {
    try {
      final history = await GuestSpaceHistory.open();
      if (!mounted) return;
      _history = history;
    } catch (error) {
      debugPrint('[LinkNest] 加载最近访客空间失败 reason=${error.runtimeType}');
    }
    if (await _refreshWifiState()) await _discoverCurrentSpace();
  }

  Future<bool> _refreshWifiState() async {
    if (_wifiCheckInFlight) return _wifiConnected == true;
    _wifiCheckInFlight = true;
    var connected = false;
    try {
      final addresses = await _native.getLocalAddresses();
      connected = addresses.any(
        (address) =>
            address['kind'] == 'wifi' ||
            isLikelyWifiInterface(address['interface']?.toString() ?? ''),
      );
    } catch (error) {
      debugPrint('[LinkNest] 检查访客 Wi-Fi 状态失败 reason=${error.runtimeType}');
    } finally {
      _wifiCheckInFlight = false;
    }
    if (!mounted) return connected;
    final changed = _wifiConnected != connected;
    if (changed) {
      debugPrint('[LinkNest] 访客 Wi-Fi 已连接 connected=$connected');
      setState(() => _wifiConnected = connected);
    }
    await _startScanner();
    return connected;
  }

  void _handleCapture(BarcodeCapture capture) {
    if (_busy || _scanConsumed) return;
    String? value;
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null && rawValue.trim().isNotEmpty) {
        value = rawValue;
        break;
      }
    }
    if (value == null) return;

    if (value == _lastWifiCode && _wifi.state == WifiJoinState.connected) {
      return;
    }
    unawaited(_handleScannedValue(value));
  }

  Future<void> _handleScannedValue(String value) async {
    _scanConsumed = true;
    try {
      if (value.startsWith('WIFI:')) {
        if (_useSystemCameraForWifi) {
          debugPrint('[LinkNest] iOS 暂停 App 内热点连接，提示使用系统相机');
          if (mounted) {
            setState(
              () => _errorMessage =
                  '请使用 iPhone 系统相机扫描 Wi-Fi 码，再返回 LinkNest 扫描空间码。',
            );
          }
        } else {
          final credentials = WifiCredentials.parse(value);
          _lastWifiCode = value;
          await _connectWifi(credentials);
        }
      } else {
        // Wi-Fi 密码不能出现在空间地址输入框中。
        SpaceInvite.parse(value);
        _urlController.text = value;
        await _connect(value);
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } finally {
      _scanConsumed = false;
    }
  }

  Future<void> _connect(String input, {String? expectedSpaceId}) async {
    final SpaceInvite invite;
    try {
      invite = SpaceInvite.parse(input);
    } on FormatException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
      return;
    }
    await _connectInvites([invite], expectedSpaceId: expectedSpaceId);
  }

  Future<void> _connectInvites(
    List<SpaceInvite> invites, {
    String? expectedSpaceId,
    String? expectedSessionId,
  }) async {
    if (_busy || invites.isEmpty) return;
    if (!await _refreshWifiState()) {
      if (mounted) {
        setState(
          () => _errorMessage = _historyOnly
              ? '请先连接发起者当前热点，再重试上次空间地址。'
              : _useSystemCameraForWifi
              ? '请先用 iPhone 系统相机扫描 Wi-Fi 码连接热点，再返回扫描空间码'
              : '请先扫描 Wi-Fi 码或手动连接发起者热点',
        );
      }
      return;
    }
    if (!mounted || _busy) return;
    setState(() {
      _connecting = true;
      _errorMessage = null;
    });
    debugPrint(
      '[LinkNest] 访客开始连接空间 inviteCount=${invites.length} '
      'expectedSpaceIdPresent=${expectedSpaceId != null}',
    );

    GuestDataSource? dataSource;
    Object? lastError;
    try {
      await _stopScanner();
      for (var index = 0; index < invites.length; index++) {
        final invite = invites[index];
        GuestApiClient? client;
        try {
          client =
              widget.clientFactory?.call(invite) ??
              GuestApiClient(invite: invite);
          final handshake = await _handshakeWithWifiSwitchRetry(client);
          if (expectedSpaceId != null && handshake.spaceId != expectedSpaceId) {
            throw const GuestApiException(
              'SPACE_MISMATCH',
              '保存的地址已指向其他空间，不能进入。',
            );
          }
          if (expectedSessionId != null &&
              handshake.sessionId != expectedSessionId) {
            throw const GuestApiException(
              'SESSION_MISMATCH',
              '空间已重新开启，请重新查找后再进入。',
            );
          }
          debugPrint(
            '[LinkNest] 访客空间握手成功 candidate=${index + 1} '
            'spaceId=${handshake.spaceId} protocolVersion=${handshake.protocolVersion}',
          );
          _wifi.confirmHostConnection();
          await _rememberSpace(handshake, invite);
          dataSource = _createGuestDataSource(client, handshake);
          client = null;
          break;
        } catch (error) {
          lastError = error;
          debugPrint(
            '[LinkNest] 访客空间候选连接失败 candidate=${index + 1} '
            'reason=${error.runtimeType}',
          );
        } finally {
          client?.close();
        }
      }
      if (dataSource == null) {
        if (lastError case final GuestApiException error) throw error;
        if (lastError case final FormatException error) throw error;
        throw const GuestApiException('CONNECTION_FAILED', '连接空间失败，请稍后重试。');
      }

      if (!mounted) {
        await dataSource.close();
        dataSource = null;
        return;
      }
      await pushLinkNestRoute<void>(
        context,
        MaterialPageRoute(
          builder: (_) => SpaceGalleryScreen(
            dataSource: dataSource!,
            native: _native,
            guestMode: true,
          ),
        ),
      );
      debugPrint('[LinkNest] 访客已退出空间画廊');
      dataSource = null;
      await _wifi.release();
      if ((_historyOnly || widget.initialSpace != null) && mounted) {
        popLinkNest(context);
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } on GuestApiException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } catch (error) {
      debugPrint('[LinkNest] 访客连接空间失败 reason=${error.runtimeType}');
      if (mounted) setState(() => _errorMessage = '连接空间失败，请稍后重试。');
    } finally {
      await dataSource?.close();
      if (mounted) {
        setState(() {
          _connecting = false;
          _scanConsumed = false;
        });
        await _startScanner();
      }
    }
  }

  Future<SpaceHandshake> _handshakeWithWifiSwitchRetry(
    GuestApiClient client,
  ) async {
    if (_wifi.state != WifiJoinState.verificationPending) {
      return client.handshake();
    }
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await client.handshake();
      } on GuestApiException catch (error) {
        if (!mounted ||
            (error.code != 'CONNECTION_FAILED' &&
                error.code != 'CONNECTION_TIMEOUT') ||
            DateTime.now().isAfter(deadline)) {
          rethrow;
        }
        debugPrint('[LinkNest] 等待 Wi-Fi 切换后重试空间握手 attempt=$attempt');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> _rememberSpace(
    SpaceHandshake handshake,
    SpaceInvite invite,
  ) async {
    try {
      final history = _history ?? await GuestSpaceHistory.open();
      await history.remember(
        spaceId: handshake.spaceId,
        name: handshake.spaceName,
        invite: invite,
      );
      _history = history;
    } catch (error) {
      debugPrint('[LinkNest] 保存最近访客空间失败 reason=${error.runtimeType}');
    }
  }

  GuestDataSource _createGuestDataSource(
    GuestApiClient client,
    SpaceHandshake handshake,
  ) {
    final dataSource = GuestDataSource(
      client,
      handshake: handshake,
      transferRuntime: NativeGuestTransferRuntime(_native),
      reconnectAddressProvider: _native.getWifiGatewayCandidates,
      onInviteChanged: _rememberSpace,
    );
    unawaited(_initializeGuestMediaCache(dataSource));
    return dataSource;
  }

  Future<void> _initializeGuestMediaCache(GuestDataSource dataSource) async {
    GuestMediaCache? mediaCache;
    try {
      mediaCache = await GuestMediaCache.open(
        freeDiskBytesProvider: _native.getFreeDiskBytes,
      );
    } on Object catch (error) {
      debugPrint('[LinkNest] 初始化访客媒体缓存失败 reason=${error.runtimeType}');
    }
    if (mediaCache != null) {
      await dataSource.attachMediaCache(mediaCache: mediaCache);
    }
  }

  Future<void> _discoverCurrentSpace() async {
    if (_historyOnly || _discovering || _busy || _wifiConnected != true) return;
    setState(() {
      _discovering = true;
      _errorMessage = null;
    });
    final epoch = ++_discoveryEpoch;
    try {
      final discovered = await _discovery.findReachable();
      if (!mounted || discovered.isEmpty || _busy || epoch != _discoveryEpoch) {
        return;
      }
      await _stopScanner();
      if (!mounted || _busy || epoch != _discoveryEpoch) return;
      final selected = await showLinkNestDialog<DiscoveredSpace>(
        context: context,
        builder: (context) => LinkNestDialog(
          title: discovered.length == 1 ? '发现正在运行的空间' : '发现多个空间',
          actions: [
            LinkNestButton(
              onPressed: () => popLinkNest(context),
              label: '暂不进入',
              variant: FButtonVariant.secondary,
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final space in discovered)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LinkNestButton(
                    label: '进入 ${space.name}',
                    onPressed: () => popLinkNest(context, space),
                  ),
                ),
            ],
          ),
        ),
      );
      if (!mounted) return;
      if (selected != null) {
        await _connectInvites(
          selected.invites,
          expectedSpaceId: selected.spaceId,
          expectedSessionId: selected.sessionId,
        );
      } else {
        await _startScanner();
      }
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _connectHistory() async {
    final space = widget.historySpace;
    if (space == null || !mounted || _busy) return;
    debugPrint('[LinkNest] 正在重进参与者历史空间，仅尝试上次地址');
    await _connect(space.inviteUrl, expectedSpaceId: space.spaceId);
  }

  Widget _buildHistoryConnection() => LinkNestPage(
    title: '进入历史空间',
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        LinkNestPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.historySpace!.name,
                style: context.theme.typography.body.lg,
              ),
              const SizedBox(height: 12),
              LinkNestNotice(
                message: _errorMessage ?? '正在尝试上次空间地址…',
                error: _errorMessage != null,
              ),
              const SizedBox(height: 16),
              LinkNestButton(
                label: _connecting ? '正在连接…' : '重试连接',
                busy: _connecting,
                onPressed: _busy ? null : _connectHistory,
              ),
              const SizedBox(height: 8),
              if (_useSystemCameraForWifi) ...[
                LinkNestButton(
                  label: '系统相机连接指引',
                  variant: FButtonVariant.secondary,
                  onPressed: _busy ? null : _showSystemCameraInstructions,
                ),
                const SizedBox(height: 8),
              ],
              LinkNestButton(
                label: '手动连接 Wi-Fi',
                variant: FButtonVariant.secondary,
                onPressed: _busy ? null : _manualWifi,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _buildDiscoveredConnection() {
    final space = widget.initialSpace!;
    return LinkNestPage(
      title: '进入空间',
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: LinkNestPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(space.name, style: context.theme.typography.body.lg),
                const SizedBox(height: 12),
                LinkNestNotice(
                  message: _errorMessage ?? '正在连接空间…',
                  error: _errorMessage != null,
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  LinkNestButton(
                    label: '重试连接',
                    onPressed: _busy
                        ? null
                        : () => _connectInvites(
                            space.invites,
                            expectedSpaceId: space.spaceId,
                            expectedSessionId: space.sessionId,
                          ),
                  ),
                  const SizedBox(height: 8),
                  LinkNestButton(
                    label: '扫码加入',
                    variant: FButtonVariant.secondary,
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() {
                              _showScannerFallback = true;
                              _errorMessage = null;
                            });
                            unawaited(_startScanner());
                          },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _stopScanner() async {
    try {
      await _scannerController.stop();
    } on MobileScannerException {
      // 相机未完成初始化时仍可继续使用地址或局域网发现连接。
    }
  }

  Future<void> _startScanner() async {
    if (_historyOnly ||
        (widget.initialSpace != null && !_showScannerFallback) ||
        !mounted ||
        !_foreground ||
        _busy ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    try {
      await _scannerController.start();
    } on MobileScannerException {
      // 扫码错误由 errorBuilder 展示，地址和局域网发现始终可用。
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_historyOnly) return _buildHistoryConnection();
    if (widget.initialSpace != null && !_showScannerFallback) {
      return _buildDiscoveredConnection();
    }
    final theme = context.theme;
    return LinkNestPage(
      title: '加入空间',
      actions: [
        if (_discovering)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox.square(dimension: 20, child: FCircularProgress()),
          )
        else
          FButton.icon(
            onPress: _busy ? null : _discoverCurrentSpace,
            variant: FButtonVariant.ghost,
            semanticsLabel: '查找当前空间',
            semanticsTooltip: '查找当前空间',
            child: const Icon(FLucideIcons.radar),
          ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          LinkNestPanel(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '先连热点，再进空间',
                        style: theme.typography.body.lg.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _useSystemCameraForWifi
                            ? '先用 iPhone 系统相机扫描 Wi-Fi 码并确认加入，返回后用下方相机扫描空间码。已连接热点可直接扫空间码。'
                            : '扫描 Wi-Fi 码并按系统提示连接，再扫描空间码。已经连接热点时可直接扫空间码。',
                        style: theme.typography.body.sm.copyWith(
                          color: theme.colors.mutedForeground,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: MobileScanner(
                      controller: _scannerController,
                      onDetect: _handleCapture,
                      placeholderBuilder: (_) => const ColoredBox(
                        color: Colors.black,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      errorBuilder: (_, error) => ColoredBox(
                        color: Colors.black87,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              error.errorCode ==
                                      MobileScannerErrorCode.permissionDenied
                                  ? '相机权限被拒绝。可在系统设置中开启权限，或使用下方手动输入。'
                                  : '相机暂时不可用，请使用下方手动输入。',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 12),
                      if (_wifi.message case final message?) ...[
                        LinkNestNotice(
                          message: message,
                          error: _wifi.state == WifiJoinState.failed,
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (_useSystemCameraForWifi)
                        LinkNestButton(
                          label: '系统相机连接指引',
                          icon: FLucideIcons.camera,
                          variant: FButtonVariant.secondary,
                          onPressed: _busy
                              ? null
                              : _showSystemCameraInstructions,
                        )
                      else if (_wifi.connecting)
                        LinkNestButton(
                          label: '取消连接',
                          variant: FButtonVariant.secondary,
                          onPressed: () async {
                            await _wifi.cancel();
                            await _startScanner();
                          },
                        )
                      else if (_wifi.credentials != null &&
                          _wifi.state != WifiJoinState.connected)
                        LinkNestButton(
                          label: '重试 Wi-Fi 连接',
                          icon: FLucideIcons.rotateCw,
                          variant: FButtonVariant.secondary,
                          onPressed: _busy
                              ? null
                              : () => _connectWifi(_wifi.credentials!),
                        ),
                      LinkNestButton(
                        label: '手动连接 Wi-Fi',
                        icon: FLucideIcons.wifi,
                        variant: FButtonVariant.ghost,
                        onPressed: _busy ? null : _manualWifi,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          LinkNestPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FTextField(
                  control: FTextFieldControl.managed(
                    controller: _urlController,
                  ),
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  label: const Text('空间地址'),
                  hint: '粘贴发起者提供的空间地址',
                  onSubmit: _busy ? null : _connect,
                ),
                if (_errorMessage case final message?) ...[
                  const SizedBox(height: 12),
                  LinkNestNotice(message: message, error: true),
                ],
                const SizedBox(height: 16),
                LinkNestButton(
                  label: _connecting ? '正在连接…' : '连接空间',
                  busy: _connecting,
                  icon: FLucideIcons.link,
                  onPressed: _busy ? null : () => _connect(_urlController.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
