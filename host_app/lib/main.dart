import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'app_motion.dart';
import 'app_theme.dart';
import 'app_ui.dart';
import 'host_health.dart';
import 'host_network.dart';
import 'host_data_source.dart';
import 'history_screen.dart';
import 'guest_space_history.dart';
import 'join_space.dart';
import 'native.dart';
import 'persistence.dart';
import 'qrcodes.dart';
import 'server.dart';
import 'settings.dart';
import 'settings_state.dart';
import 'space_gallery.dart';
import 'space_discovery.dart';
import 'space_state.dart';

class _HostWifiCredentials {
  const _HostWifiCredentials({required this.ssid, required this.password});

  final String ssid;
  final String password;
}

class _HostSetupCancelled implements Exception {
  const _HostSetupCancelled(this.reason);

  final String reason;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final name in ['Lora', 'Raleway']) {
      final license = await rootBundle.loadString('assets/fonts/$name-OFL.txt');
      yield LicenseEntryWithLineBreaks([name], license);
    }
  });
  await initPersistence();
  runApp(const LinkNestApp());
}

class LinkNestApp extends StatelessWidget {
  const LinkNestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => MaterialApp(
        title: 'LinkNest',
        themeMode: mode,
        theme: linkNestLightTheme,
        darkTheme: linkNestDarkTheme,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: linkNestLocalizations,
        builder: (context, child) => LinkNestTheme(child: child!),
        home: const RoleSelectionScreen(),
      ),
    );
  }
}

class RoleSelectionScreen extends StatefulWidget {
  const RoleSelectionScreen({super.key, this.server, this.native});
  final LinkNestServer? server;
  final LinkNestNative? native;

  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends State<RoleSelectionScreen>
    with WidgetsBindingObserver {
  late final LinkNestServer _server = widget.server ?? LinkNestServer();
  late final LinkNestNative _native = widget.native ?? LinkNestNative();
  final LinkNestDiscovery _discovery = const LinkNestDiscovery();
  final Set<String> _shownSessions = {};
  Timer? _discoveryTimer;
  bool _discovering = false;
  bool _foreground = true;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_discoverOnHome());
    });
    if (Platform.isAndroid || Platform.isIOS) {
      _discoveryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(_discoverOnHome());
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _discoveryTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) unawaited(_discoverOnHome());
  }

  Future<void> _discoverOnHome() async {
    if (!mounted ||
        !_foreground ||
        _opening ||
        _discovering ||
        _server.running ||
        !(Platform.isAndroid || Platform.isIOS) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _discovering = true;
    try {
      final addresses = await _native.getLocalAddresses();
      final connected = addresses.any(
        (address) =>
            address['kind'] == 'wifi' ||
            isLikelyWifiInterface(address['interface']?.toString() ?? ''),
      );
      if (!connected || !mounted || _opening) return;
      final spaces = await _discovery.findReachable(
        timeout: const Duration(seconds: 2),
      );
      if (!mounted ||
          _opening ||
          !_foreground ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final newSpaces = spaces
          .where(
            (space) =>
                !_shownSessions.contains('${space.spaceId}:${space.sessionId}'),
          )
          .toList();
      if (newSpaces.isEmpty) return;
      debugPrint('[LinkNest] 首页发现可进入的空间 count=${newSpaces.length}');
      final selected = await showLinkNestDialog<DiscoveredSpace>(
        context: context,
        builder: (dialogContext) => LinkNestDialog(
          title: newSpaces.length == 1 ? '发现正在运行的空间' : '发现多个空间',
          actions: [
            LinkNestButton(
              label: '暂不进入',
              variant: FButtonVariant.secondary,
              onPressed: () => popLinkNest(dialogContext),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final space in newSpaces)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LinkNestButton(
                    label: '进入 ${space.name}',
                    onPressed: () => popLinkNest(dialogContext, space),
                  ),
                ),
            ],
          ),
        ),
      );
      _shownSessions.addAll(
        newSpaces.map((space) => '${space.spaceId}:${space.sessionId}'),
      );
      if (!mounted || selected == null) return;
      setState(() => _opening = true);
      try {
        await pushLinkNestRoute<void>(
          context,
          MaterialPageRoute(
            builder: (_) =>
                JoinSpaceScreen(native: _native, initialSpace: selected),
          ),
        );
      } finally {
        if (mounted) setState(() => _opening = false);
      }
    } catch (error) {
      debugPrint('[LinkNest] 首页局域网空间发现失败 reason=${error.runtimeType}');
    } finally {
      _discovering = false;
    }
  }

  Future<void> _createSpace() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await _openHost();
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _openHost({String? name, Space? resumeSpace}) =>
      pushLinkNestRoute<void>(
        context,
        // 启动时保留首页背景，待热点及服务就绪后直接显示二维码。
        PageRouteBuilder<void>(
          opaque: false,
          transitionDuration: LinkNestMotion.duration(
            context,
            LinkNestMotion.enter,
          ),
          reverseTransitionDuration: LinkNestMotion.duration(
            context,
            LinkNestMotion.exit,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              FadeTransition(
                opacity: animation.drive(
                  CurveTween(curve: LinkNestMotion.curve),
                ),
                child: child,
              ),
          pageBuilder: (_, animation, secondaryAnimation) => HomeScreen(
            server: _server,
            native: _native,
            initialName: name,
            resumeSpace: resumeSpace,
          ),
        ),
      );

  Future<void> _openHistory() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      debugPrint('[LinkNest] 首页打开统一历史空间');
      final selected = await pushLinkNestRoute<Object>(
        context,
        MaterialPageRoute(
          builder: (_) => HistorySpacesScreen(
            server: _server,
            allowResume: true,
            includeJoinedSpaces: true,
          ),
        ),
      );
      if (!mounted) return;
      if (selected is Space) {
        await _openHost(resumeSpace: selected);
      } else if (selected is RecentGuestSpace) {
        await pushLinkNestRoute<void>(
          context,
          MaterialPageRoute(
            builder: (_) =>
                JoinSpaceScreen(native: _native, historySpace: selected),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Scaffold(
      backgroundColor: theme.colors.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                  children: [
                    Center(
                      child: ClipRRect(
                        key: const ValueKey('home-logo'),
                        borderRadius: BorderRadius.circular(14),
                        child: Image.asset(
                          'assets/brand/linknest-icon.png',
                          width: 52,
                          height: 52,
                          cacheWidth: 156,
                          semanticLabel: 'LinkNest：相聚与分享',
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '相聚即刻，美好即享',
                      textAlign: TextAlign.center,
                      style: theme.typography.display.xl2.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '无需网络，欢聚时刻原画质极速互传。',
                      textAlign: TextAlign.center,
                      style: theme.typography.body.md.copyWith(
                        color: theme.colors.mutedForeground,
                      ),
                    ),
                    const SizedBox(height: 28),
                    LinkNestPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '发起共享',
                            style: theme.typography.body.lg.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '创建或继续一次相聚，将大家上传的照片和视频保存在这个空间。',
                            style: theme.typography.body.sm.copyWith(
                              color: theme.colors.mutedForeground,
                            ),
                          ),
                          const SizedBox(height: 20),
                          LinkNestButton(
                            label: '创建空间',
                            icon: FLucideIcons.plus,
                            onPressed: _opening ? null : _createSpace,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    LinkNestPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '接收与上传',
                            style: theme.typography.body.lg.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '连接发起者的二维码，加入后即可上传或保存原文件。',
                            style: theme.typography.body.sm.copyWith(
                              color: theme.colors.mutedForeground,
                            ),
                          ),
                          const SizedBox(height: 20),
                          LinkNestButton(
                            label: '加入空间',
                            icon: FLucideIcons.scanLine,
                            variant: FButtonVariant.secondary,
                            onPressed: _opening
                                ? null
                                : () {
                                    debugPrint('[LinkNest] 首页进入加入空间');
                                    pushLinkNestRoute<void>(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            JoinSpaceScreen(native: _native),
                                      ),
                                    );
                                  },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Center(
                      child: FButton(
                        key: const ValueKey('home-about'),
                        variant: FButtonVariant.ghost,
                        onPress: () => showLinkNestAbout(context),
                        child: Flexible(
                          child: Text(
                            '关于 LinkNest',
                            textAlign: TextAlign.center,
                            style: theme.typography.body.sm.copyWith(
                              color: theme.colors.mutedForeground,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                Positioned(
                  top: 8,
                  right: 12,
                  child: FButton.icon(
                    key: const ValueKey('home-history'),
                    variant: FButtonVariant.ghost,
                    semanticsLabel: '历史空间',
                    semanticsTooltip: '历史空间',
                    onPress: _opening ? null : _openHistory,
                    child: const Icon(FLucideIcons.history),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 名称草稿只存在于这次弹窗，取消或再次打开时不会回填。
class CreateSpaceNameDialog extends StatefulWidget {
  const CreateSpaceNameDialog({super.key, this.onConfirmed});
  final ValueChanged<String>? onConfirmed;
  @override
  State<CreateSpaceNameDialog> createState() => _CreateSpaceNameDialogState();
}

class _CreateSpaceNameDialogState extends State<CreateSpaceNameDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Animation<double>? _entryAnimation;
  bool _focusRequested = false;
  String? _error;
  bool _submitted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (_entryAnimation != animation) {
      _entryAnimation?.removeStatusListener(_onEntryStatus);
      _entryAnimation = animation;
      _entryAnimation?.addStatusListener(_onEntryStatus);
    }
    if (LinkNestMotion.reduced(context) ||
        animation == null ||
        animation.status == AnimationStatus.completed) {
      _scheduleNameFocus();
    }
  }

  void _onEntryStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _scheduleNameFocus();
  }

  void _scheduleNameFocus() {
    // 等展开动画结束且本帧布局完成，再让系统键盘改变布局。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusRequested || _submitted) return;
      final route = ModalRoute.of(context);
      if (route != null &&
          (!route.isCurrent ||
              route.offstage ||
              route.animation?.status == AnimationStatus.reverse ||
              (!LinkNestMotion.reduced(context) &&
                  route.animation != null &&
                  route.animation!.status != AnimationStatus.completed))) {
        return;
      }
      _focusRequested = true;
      _focusNode.requestFocus();
      debugPrint('[LinkNest] 名称弹窗展开完成，开始聚焦输入框');
    });
  }

  void _submit() {
    if (_submitted) return;
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写本次相聚名称');
      return;
    }
    _submitted = true;
    if (widget.onConfirmed case final callback?) {
      FocusScope.of(context).unfocus();
      callback(name);
    } else {
      popLinkNest(context, name);
    }
  }

  @override
  void dispose() {
    _entryAnimation?.removeStatusListener(_onEntryStatus);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LinkNestDialog(
    title: '为这次相聚起个名字',
    actions: [
      LinkNestButton(label: '确定', onPressed: _submit),
      LinkNestButton(
        label: '取消',
        variant: FButtonVariant.secondary,
        onPressed: () => popLinkNest(context),
      ),
    ],
    child: FTextField(
      control: FTextFieldControl.managed(controller: _controller),
      label: const Text('本次相聚名称'),
      hint: '例如：杭州三日游',
      focusNode: _focusNode,
      error: _error == null ? null : Text(_error!),
      textInputAction: TextInputAction.done,
      onSubmit: (_) => _submit(),
    ),
  );
}

/// 只有省略号更新；弹窗退出时停止计时，不刷新背后的首页。
class _CreatingSpaceDialog extends StatefulWidget {
  const _CreatingSpaceDialog({super.key, this.label = '正在创建空间'});
  final String label;

  @override
  State<_CreatingSpaceDialog> createState() => _CreatingSpaceDialogState();
}

class _CreatingSpaceDialogState extends State<_CreatingSpaceDialog> {
  Timer? _timer;
  int _dots = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    if (LinkNestMotion.reduced(context)) return;
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      setState(() => _dots = _dots % 3 + 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    key: const ValueKey('creating-space-dialog'),
    constraints: const BoxConstraints(maxWidth: 320),
    backgroundColor: context.theme.colors.background,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Semantics(
        label: widget.label,
        child: ExcludeSemantics(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: widget.label),
                TextSpan(
                  text: ('.' * _dots).padRight(3),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
            textAlign: TextAlign.center,
            style: context.theme.typography.body.lg,
          ),
        ),
      ),
    ),
  );
}

/// 首页确认创建后：启动/失败弹窗、二维码引导、空间画廊。
enum _SpacePhase { idle, guide, active }

enum _SpaceOperation { idle, starting, running, stopping }

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.server,
    this.native,
    this.initialName,
    this.resumeSpace,
  }) : assert(initialName == null || resumeSpace == null);
  final LinkNestServer? server;
  final LinkNestNative? native;
  final String? initialName;
  final Space? resumeSpace;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final LinkNestDiscovery _discovery = const LinkNestDiscovery();
  List<DiscoveredSpace> _existingSpaces = const [];
  bool _iosNetworkUnavailable = false;
  bool _preferManualNetworkOnRetry = false;
  late final LinkNestServer _server = widget.server ?? LinkNestServer();
  late final LinkNestNative _native = widget.native ?? LinkNestNative();
  late final HostDataSource _hostDataSource;

  int _currentTab = 0; // 0=空间 1=设置
  _SpacePhase _phase = _SpacePhase.idle;
  _SpaceOperation _operation = _SpaceOperation.idle;

  String? _requestedName;
  String _status = '正在准备…';
  bool _awaitingInitialStart = true;
  String _url = '';
  List<String> _urls = const [];
  String _ssid = '';
  String _wifiPassword = '';
  HostNetworkKind? _hostNetworkKind;
  String? _hostInterfaceName;
  int _onlineCount = 0;
  Timer? _timer;
  StreamSubscription<NativeHotspotState>? _hotspotStateSubscription;
  DateTime? _sharingStartedAt;
  DateTime? _hotspotStartedAt;
  DateTime? _lastVisitorSeenAt;
  DateTime? _lastPowerCheckAt;
  DateTime? _lastNetworkCheckAt;
  DateTime? _lastHotspotCheckAt;
  bool _healthCheckInFlight = false;
  bool _forceAdvertisementRefreshPending = false;
  bool _hotspotRecoveryInFlight = false;
  bool _hotspotRecoveryAttempted = false;
  bool _hotspotManualRetryAvailable = false;
  bool _iosWasBackgrounded = false;
  int _lastNotificationOnlineCount = -1;
  String _lastNotificationSpaceName = '';
  String? _notificationNotice;
  String? _lifecycleNotice;
  String? _idleNotice;
  String? _powerNotice;
  String? _hotspotNotice;
  String? _lastHotspotSnackMessage;
  String? _hostNotice;
  String? _dismissedHostNotice;
  String? _lastComposedHostNotice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    spaceName.value = '';
    _hostDataSource = HostDataSource(_server, spaceName: spaceName);
    if (Platform.isAndroid) {
      _hotspotStateSubscription = _native.hotspotStateChanges.listen(
        _handleNativeHotspotState,
      );
    }
    _requestedName = widget.initialName;
    _awaitingInitialStart =
        _requestedName != null || widget.resumeSpace != null;
    if (_awaitingInitialStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_beginStartup());
      });
    }
  }

  bool get _awaitingName =>
      _requestedName == null && widget.resumeSpace == null;

  void _confirmName(String name) {
    if (!_awaitingName) return;
    setState(() {
      _requestedName = name;
      _awaitingInitialStart = true;
    });
    debugPrint('[LinkNest] 已确认相聚名称，弹窗进入创建状态');
    unawaited(_beginStartup());
  }

  Future<void> _beginStartup() async {
    if (!mounted) return;
    _awaitingInitialStart = false;
    await _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_hotspotStateSubscription?.cancel());
    unawaited(_hostDataSource.close());
    _clearHostHealthState();
    if (_operation != _SpaceOperation.idle) unawaited(_shutdownResources());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isIOS || _operation != _SpaceOperation.running) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _iosWasBackgrounded = true;
      debugPrint('[LinkNest] iOS 发起者在共享期间进入后台');
      return;
    }
    if (state == AppLifecycleState.resumed && _iosWasBackgrounded) {
      _iosWasBackgrounded = false;
      _lifecycleNotice = '共享期间 App 曾进入后台，iOS 可能已经暂停局域网服务。请保持 LinkNest 前台，并让访客刷新；如仍无法连接，请重新确认个人热点。';
      _dismissedHostNotice = null;
      _publishHostNotice();
      unawaited(
        _refreshHostHealth(force: true, forceAdvertisementRefresh: true),
      );
    }
  }

  Future<bool> _showManualHotspotReminder({required bool retrying}) async {
    return await showLinkNestDialog<bool>(
          context: context,
          builder: (context) => LinkNestDialog(
            title: retrying ? '仍未检测到热点' : '需要手动开启热点',
            actions: [
              LinkNestButton(
                onPressed: () => popLinkNest(context, false),
                label: '退出创建',
                variant: FButtonVariant.secondary,
              ),
              LinkNestButton(
                onPressed: () => popLinkNest(context, true),
                label: '确认已开启，重新检测',
              ),
            ],
            child: Text(
              retrying ? '仍未检测到有效热点地址。请确认系统设置中的个人热点已开启；可以继续重试，或退出本次创建。' : '请先到系统设置中手动开启个人热点，然后返回 LinkNest 点“确认已开启，重新检测”。检测到有效热点地址后才会创建空间。',
            ),
          ),
        ) ??
        false;
  }

  Future<HostNetwork?> _requestManualNetwork({required bool ios}) async {
    var retrying = false;
    while (mounted) {
      if (!await _showManualHotspotReminder(retrying: retrying)) return null;
      final found = await _waitForManualNetwork(ios: ios);
      if (found != null) return found;
      retrying = true;
    }
    return null;
  }

  Future<HostNetwork?> _waitForManualNetwork({required bool ios}) async {
    if (!mounted) return null;
    setState(() => _status = '正在重新检测手动热点…');
    for (var attempt = 0; attempt < 3 && mounted; attempt++) {
      final addresses = await _native.getLocalAddresses(diagnostic: kDebugMode);
      final found = ios
          ? selectIosHostNetwork(addresses)
          : selectAndroidManualHotspotNetwork(addresses);
      final isManualHotspot = ios
          ? found?.kind == HostNetworkKind.iosPersonalHotspot
          : found?.kind == HostNetworkKind.manualHotspot;
      if (found != null && isManualHotspot) {
        debugPrint(
          '[LinkNest] 手动网络重试成功 interface=${found.interfaceName} address=${found.address}',
        );
        return HostNetwork(
          kind: HostNetworkKind.manualHotspot,
          address: found.address,
          interfaceName: found.interfaceName,
        );
      }
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    debugPrint('[LinkNest] 手动热点重试后仍无有效热点地址');
    return null;
  }

  Future<_HostWifiCredentials?> _requestNetworkCredentials({
    required String title,
    required String message,
    required String nameLabel,
    String initialSsid = '',
    String initialPassword = '',
  }) async {
    final formKey = GlobalKey<FormState>();
    final ssidController = TextEditingController(text: initialSsid);
    final passwordController = TextEditingController(text: initialPassword);
    try {
      return await showLinkNestDialog<_HostWifiCredentials>(
        context: context,
        builder: (context) => LinkNestDialog(
          title: title,
          actions: [
            LinkNestButton(
              label: '取消',
              variant: FButtonVariant.secondary,
              onPressed: () => popLinkNest(context),
            ),
            LinkNestButton(
              label: '跳过填写',
              variant: FButtonVariant.secondary,
              onPressed: () => popLinkNest(
                context,
                const _HostWifiCredentials(ssid: '', password: ''),
              ),
            ),
            LinkNestButton(
              label: '确认并生成二维码',
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                popLinkNest(
                  context,
                  _HostWifiCredentials(
                    ssid: ssidController.text.trim(),
                    password: passwordController.text,
                  ),
                );
              },
            ),
          ],
          child: Material(
            color: Colors.transparent,
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(message),
                  const SizedBox(height: 8),
                  const Text(
                    '请提醒访客先连接同一 Wi-Fi 或热点。跳过填写后不会生成 Wi-Fi 连接码，访客需手动连接后再扫描空间码。',
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: ssidController,
                    autofocus: true,
                    maxLength: 32,
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '请输入$nameLabel'
                        : null,
                    decoration: InputDecoration(labelText: nameLabel),
                  ),
                  TextFormField(
                    controller: passwordController,
                    obscureText: true,
                    validator: (value) =>
                        value == null || value.isEmpty ? '请输入密码' : null,
                    decoration: const InputDecoration(labelText: '密码'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } finally {
      ssidController.dispose();
      passwordController.dispose();
    }
  }

  Future<void> _start() async {
    if (!mounted || _operation != _SpaceOperation.idle) return;
    final preferManualNetwork = _preferManualNetworkOnRetry;
    _preferManualNetworkOnRetry = false;
    final resumeSpace = widget.resumeSpace;
    final requestedName = _requestedName?.trim() ?? '';
    if (resumeSpace == null && requestedName.isEmpty) return;
    setState(() {
      _operation = _SpaceOperation.starting;
      _status = '正在启动…';
      _existingSpaces = const [];
      _iosNetworkUnavailable = false;
    });
    debugPrint('[LinkNest] 发起者开始启动共享 resumeSpace=${resumeSpace != null}');
    try {
      final currentAddresses = await _native.getLocalAddresses();
      final hasClientWifi = Platform.isIOS
          ? currentAddresses.any((address) => address['kind'] == 'wifi')
          : Platform.isAndroid &&
                currentAddresses.any(
                  (address) => isLikelyWifiInterface(
                    address['interface']?.toString() ?? '',
                  ),
                );
      if (hasClientWifi) {
        final existing = await _discovery.findReachable(
          timeout: const Duration(seconds: 2),
        );
        if (existing.isNotEmpty) {
          debugPrint('[LinkNest] 当前局域网已有运行中的空间 count=${existing.length}');
          setState(() {
            _existingSpaces = existing;
            _operation = _SpaceOperation.idle;
            _status = '当前局域网已有运行中的空间，请作为参与者加入。';
          });
          return;
        }
      }
      final resumeSpaceId = resumeSpace?.id;
      if (resumeSpace != null) {
        spaceName.value = resumeSpace.name;
        debugPrint('[LinkNest] 发起者选择继续历史空间 id=${resumeSpace.id}');
      } else {
        spaceName.value = requestedName;
        debugPrint('[LinkNest] 发起者选择创建新空间');
      }

      await _native.setKeepAwake(true);
      var hotspot = <String, dynamic>{};
      _ssid = '';
      _wifiPassword = '';
      HostNetwork? network;
      if (Platform.isIOS) {
        network = selectIosHostNetwork(await _native.getLocalAddresses());
        if (network == null) {
          network = await _requestManualNetwork(ios: true);
          if (network == null) _preferManualNetworkOnRetry = true;
        }
      } else {
        Object? hotspotFailure;
        if (Platform.isAndroid && preferManualNetwork) {
          network = selectAndroidManualHotspotNetwork(
            await _native.getLocalAddresses(diagnostic: kDebugMode),
          );
          if (network != null) {
            debugPrint('[LinkNest] 重试优先使用手动热点地址');
          }
        }
        if (network == null) {
          try {
            hotspot = await _native.startHotspot().timeout(
              const Duration(seconds: 15),
            );
          } catch (error) {
            hotspotFailure = error;
            debugPrint(
              '[LinkNest] Android 自动热点启动失败，尝试 Wi-Fi 回退 reason=${error.runtimeType}',
            );
          }
          HostNetwork? wifiFallback;
          for (
            var attempt = 0;
            Platform.isAndroid &&
                attempt < 10 &&
                network?.kind != HostNetworkKind.androidHotspot;
            attempt++
          ) {
            final addresses = await _native.getLocalAddresses(
              diagnostic: kDebugMode,
            );
            final hotspotNetwork = selectAndroidHotspotNetwork(addresses);
            if (hotspotNetwork != null) {
              network = hotspotNetwork;
            } else {
              wifiFallback ??= selectAndroidWifiNetwork(addresses);
              if (hotspotFailure != null) network = wifiFallback;
            }
            if (kDebugMode) {
              debugPrint(
                '[LinkNest] Host 网络候选 attempt=${attempt + 1} candidates=$addresses selected=${network?.kind}/${network?.address}',
              );
            }
            if (network?.kind != HostNetworkKind.androidHotspot &&
                hotspotFailure == null &&
                attempt < 9) {
              await Future<void>.delayed(const Duration(milliseconds: 300));
            }
          }
          if (network == null) {
            network = wifiFallback;
            if (network != null) {
              debugPrint('[LinkNest] 自动热点未取得地址，切换到当前 Wi-Fi 回退');
            }
          }
          if (network?.kind == HostNetworkKind.androidWifi) {
            try {
              await _native.stopHotspot();
            } catch (error) {
              debugPrint(
                '[LinkNest] Wi-Fi 回退时清理临时热点失败 reason=${error.runtimeType}',
              );
            }
            hotspot = <String, dynamic>{};
            debugPrint('[LinkNest] Android 使用已有 Wi-Fi 建立 Host 空间');
          }
          if (network == null && Platform.isAndroid) {
            try {
              await _native.stopHotspot();
            } catch (error) {
              debugPrint(
                '[LinkNest] 等待手动热点前清理自动热点失败 reason=${error.runtimeType}',
              );
            }
            hotspot = <String, dynamic>{};
            network = await _requestManualNetwork(ios: false);
            if (network == null) _preferManualNetworkOnRetry = true;
            if (network != null) {
              debugPrint('[LinkNest] 使用检测到的手动热点地址');
            }
          }
        }
        if (network == null && Platform.isAndroid) {
          throw StateError(
            '未检测到可用的 Wi-Fi 或手动热点局域网地址${hotspotFailure == null ? '' : '；自动热点启动失败'}。',
          );
        }
      }
      if (network?.kind == HostNetworkKind.iosWifi) {
        final credentials = await _requestNetworkCredentials(
          title: '正在使用 Wi-Fi 创建空间',
          message: '由于 iOS 系统限制，LinkNest 无法自动读取 Wi-Fi 名称和密码。请输入当前 Wi-Fi 名称和密码，生成访客连接二维码。密码仅用于本次二维码，不会保存。',
          nameLabel: 'Wi-Fi 名称',
        );
        if (credentials == null) {
          throw const _HostSetupCancelled('iOS Wi-Fi credentials dismissed');
        }
        _ssid = credentials.ssid;
        _wifiPassword = credentials.password;
      } else if (network?.kind == HostNetworkKind.androidWifi) {
        _ssid = await _native.getCurrentWifiSsid();
        if (_ssid.isEmpty || _wifiPassword.isEmpty) {
          final credentials = await _requestNetworkCredentials(
            title: '需要 Wi-Fi 名称和密码',
            message:
                '系统无法自动获取当前 Wi-Fi 的${_ssid.isEmpty ? '名称和' : ''}密码。请输入 Wi-Fi 名称和密码，生成访客连接二维码。密码仅用于本次二维码，不会保存。',
            nameLabel: 'Wi-Fi 名称',
            initialSsid: _ssid,
            initialPassword: _wifiPassword,
          );
          if (credentials == null) {
            throw const _HostSetupCancelled(
              'Android Wi-Fi credentials dismissed',
            );
          }
          _ssid = credentials.ssid;
          _wifiPassword = credentials.password;
        }
      } else if (network?.kind == HostNetworkKind.manualHotspot ||
          network?.kind == HostNetworkKind.iosPersonalHotspot) {
        final credentials = await _requestNetworkCredentials(
          title: '输入手动热点信息',
          message: '已检测到手动热点。请输入热点名称和密码，生成访客连接二维码。密码仅用于本次二维码，不会保存。',
          nameLabel: '热点名称',
        );
        if (credentials == null) {
          _preferManualNetworkOnRetry = true;
          throw const _HostSetupCancelled(
            'manual hotspot credentials dismissed',
          );
        }
        _ssid = credentials.ssid;
        _wifiPassword = credentials.password;
      }
      if (network == null && (Platform.isIOS || Platform.isAndroid)) {
        throw const _HostSetupCancelled('manual network setup dismissed');
      }
      debugPrint(
        '[LinkNest] 发起者热点启动完成 ssidPresent=${(hotspot['ssid']?.toString() ?? '').isNotEmpty} '
        'passwordPresent=${(hotspot['password']?.toString() ?? '').isNotEmpty}',
      );
      await _server.start(
        newSpaceName: resumeSpaceId == null ? requestedName : null,
        resumeSpaceId: resumeSpaceId,
        selectedAddress: network?.address,
        selectedInterface: network?.interfaceName,
        bindSelectedAddress: Platform.isIOS || Platform.isAndroid,
      );
      var notificationPermissionGranted = true;
      if (Platform.isAndroid) {
        notificationPermissionGranted = await _native
            .startHostForegroundService(
              spaceName: spaceName.value,
              onlineCount: 0,
            );
      }
      final url = _server.inviteUrl;
      final urls = _server.inviteUrls;

      String ssid = _ssid;
      String wifiPassword = _wifiPassword;
      if (Platform.isAndroid &&
          network?.kind == HostNetworkKind.androidHotspot) {
        ssid = hotspot['ssid']?.toString() ?? '';
        wifiPassword = hotspot['password']?.toString() ?? '';
      } else if (Platform.isAndroid) {
        ssid = _ssid;
        wifiPassword = _wifiPassword;
      }

      if (!mounted) {
        await _shutdownResources();
        return;
      }
      final startedAt = DateTime.now();
      _sharingStartedAt = startedAt;
      _hotspotStartedAt = startedAt;
      _lastVisitorSeenAt = null;
      _lastPowerCheckAt = null;
      _lastNetworkCheckAt = null;
      _lastHotspotCheckAt = null;
      _hotspotRecoveryAttempted = false;
      _hotspotManualRetryAvailable = false;
      _lastNotificationOnlineCount = 0;
      _lastNotificationSpaceName = spaceName.value;
      _notificationNotice = Platform.isAndroid && !notificationPermissionGranted
          ? '通知权限未开启。共享仍在运行，但常驻通知不会显示在通知栏；可在系统设置中为 LinkNest 开启通知。'
          : null;
      _lifecycleNotice = null;
      _idleNotice = null;
      _powerNotice = null;
      _hotspotNotice = null;
      _dismissedHostNotice = null;
      _lastComposedHostNotice = null;
      _hostNotice = _visibleHostNotice();
      setState(() {
        _operation = _SpaceOperation.running;
        _phase = _SpacePhase.guide;
        _url = url;
        _urls = urls;
        _ssid = ssid;
        _wifiPassword = wifiPassword;
        _hostNetworkKind = network?.kind;
        _hostInterfaceName = network?.interfaceName;
        _status = '共享中';
      });
      debugPrint(
        '[LinkNest] 发起者共享已就绪 resumeSpace=${resumeSpaceId != null} '
        'addressCount=${urls.length} notificationPermissionGranted=$notificationPermissionGranted',
      );

      // 每 3 秒刷新在线人数。
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(_refreshHostHealth());
      });
      unawaited(_refreshHostHealth(force: true));
    } on _HostSetupCancelled catch (cancelled) {
      debugPrint('[LinkNest] Host setup cancelled reason=${cancelled.reason}');
      await _shutdownResources();
      if (!mounted) return;
      spaceName.value = '';
      setState(() {
        _operation = _SpaceOperation.idle;
        _phase = _SpacePhase.idle;
        _status = '';
      });
    } catch (e) {
      debugPrint('[LinkNest] 发起者启动失败 reason=${e.runtimeType}');
      final cleanupErrors = await _shutdownResources();
      if (!mounted) return;
      spaceName.value = '';
      setState(() {
        _operation = _SpaceOperation.idle;
        _phase = _SpacePhase.idle;
        _status = cleanupErrors.isEmpty
            ? '启动失败: $e'
            : '启动失败: $e（清理异常 ${cleanupErrors.length} 项）';
      });
    }
  }

  Future<void> _joinExistingSpace(DiscoveredSpace space) async {
    await pushLinkNestRoute<void>(
      context,
      MaterialPageRoute(
        builder: (_) => JoinSpaceScreen(native: _native, initialSpace: space),
      ),
    );
    if (mounted) popLinkNest(context);
  }

  Future<void> _renameActiveSpace(String name) async {
    await _server.renameActiveSpace(name);
    debugPrint('[LinkNest] 当前空间名称已持久化');
  }

  Future<void> _requestCloseSpace() async {
    if (_operation != _SpaceOperation.running) return;
    final online = _server.onlineCount;
    if (online > 0) {
      debugPrint('[LinkNest] 当前仍有访客在线，阻止关闭空间 onlineCount=$online');
      if (mounted && _onlineCount != online) {
        setState(() => _onlineCount = online);
      }
      if (!mounted) return;
      await showLinkNestDialog<void>(
        context: context,
        builder: (context) => LinkNestDialog(
          title: '暂时不能关闭',
          actions: [
            LinkNestButton(
              onPressed: () => popLinkNest(context),
              label: '知道了',
              variant: FButtonVariant.secondary,
            ),
          ],
          child: Text('当前仍有 $online 位访客在线，请等待访客退出后再关闭空间。'),
        ),
      );
      return;
    }
    if (!mounted) return;
    final confirmed = await showLinkNestDialog<bool>(
      context: context,
      builder: (context) => LinkNestDialog(
        title: '关闭空间？',
        actions: [
          LinkNestButton(
            onPressed: () => popLinkNest(context, false),
            label: '取消',
            variant: FButtonVariant.secondary,
          ),
          LinkNestButton(
            onPressed: () => popLinkNest(context, true),
            label: '关闭空间',
            variant: FButtonVariant.destructive,
          ),
        ],
        child: const Text('关闭后访客将无法继续访问，当前共享会话会结束。'),
      ),
    );
    if (confirmed == true) {
      debugPrint('[LinkNest] 已确认关闭空间');
      await _stop();
    }
  }

  Future<void> _requestForceCloseSpace() async {
    if (_operation != _SpaceOperation.running || !mounted) return;
    final online = _server.onlineCount;
    final confirmed = await showLinkNestDialog<bool>(
      context: context,
      builder: (context) => LinkNestDialog(
        title: '强制关闭空间？',
        actions: [
          LinkNestButton(
            onPressed: () => popLinkNest(context, false),
            label: '取消',
            variant: FButtonVariant.secondary,
          ),
          LinkNestButton(
            onPressed: () => popLinkNest(context, true),
            label: '强制关闭',
            variant: FButtonVariant.destructive,
          ),
        ],
        child: Text(
          online > 0
              ? '当前仍有 $online 位访客在线。强制关闭会立即断开所有连接和正在进行的传输。'
              : '强制关闭会立即停止当前空间和正在进行的传输。',
        ),
      ),
    );
    if (confirmed != true) return;
    debugPrint('[LinkNest] 已确认强制关闭空间 onlineCount=$online');
    await _stop();
  }

  void _handleBlockedBack(bool didPop, Object? result) {
    if (didPop ||
        _phase == _SpacePhase.idle ||
        _operation == _SpaceOperation.idle ||
        !mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('共享期间请使用左侧退出图标。')));
  }

  Future<void> _stop() async {
    if (_operation == _SpaceOperation.idle ||
        _operation == _SpaceOperation.stopping) {
      return;
    }
    if (mounted) {
      setState(() {
        _operation = _SpaceOperation.stopping;
        _status = '正在停止...';
      });
    }
    final errors = await _shutdownResources();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    setState(() {
      _operation = _SpaceOperation.idle;
      _status = errors.isEmpty ? '已停止' : '已停止，清理异常 ${errors.length} 项';
    });
    if (Navigator.of(context).canPop()) popLinkNest(context);
  }

  Future<List<Object>> _shutdownResources() async {
    final errors = <Object>[];
    _timer?.cancel();
    _timer = null;
    if (Platform.isAndroid) {
      try {
        await _native.stopHostForegroundService();
      } catch (e) {
        errors.add(e);
        debugPrint('[LinkNest] 停止发起者前台服务失败 reason=${e.runtimeType}');
      }
    }
    try {
      await _server.stop();
    } catch (e) {
      errors.add(e);
      debugPrint('[LinkNest] 停止 HTTP 服务失败 reason=${e.runtimeType}');
    }
    try {
      await _native.stopHotspot();
    } catch (e) {
      errors.add(e);
      debugPrint('[LinkNest] 停止热点失败 reason=${e.runtimeType}');
    }
    try {
      await _native.setKeepAwake(false);
    } catch (e) {
      errors.add(e);
      debugPrint('[LinkNest] 关闭屏幕常亮失败 reason=${e.runtimeType}');
    }
    return errors;
  }

  Future<void> _refreshHostHealth({
    bool force = false,
    bool forceAdvertisementRefresh = false,
  }) async {
    if (forceAdvertisementRefresh) _forceAdvertisementRefreshPending = true;
    if (_operation != _SpaceOperation.running) {
      _forceAdvertisementRefreshPending = false;
      return;
    }
    if (_healthCheckInFlight) return;
    final shouldForceAdvertisementRefresh = _forceAdvertisementRefreshPending;
    _healthCheckInFlight = true;
    try {
      final now = DateTime.now();
      final onlineCount = _server.onlineCount;
      if (onlineCount > 0) _lastVisitorSeenAt = now;

      if (Platform.isIOS) {
        _idleNotice = HostHealthPolicy.iosIdleNotice(
          now: now,
          sharingStartedAt: _sharingStartedAt ?? now,
          lastVisitorSeenAt: _lastVisitorSeenAt,
          onlineCount: onlineCount,
        );
        if (force ||
            shouldForceAdvertisementRefresh ||
            _lastNetworkCheckAt == null ||
            now.difference(_lastNetworkCheckAt!) >=
                const Duration(seconds: 15)) {
          _lastNetworkCheckAt = now;
          try {
            final network = selectIosHostNetwork(
              await _native.getLocalAddresses(),
            );
            if (network == null) {
              if (!_iosNetworkUnavailable) {
                _iosNetworkUnavailable = true;
                await _server.pauseNetworkAdvertisement();
              }
              _forceAdvertisementRefreshPending = false;
              _hotspotNotice = '当前局域网地址已失效，请检查个人热点或 Wi-Fi。访客暂时无法连接。';
              debugPrint('[LinkNest] iOS 发起者未找到可用的共享网络地址');
            } else {
              final currentHost = Uri.tryParse(_server.inviteUrl)?.host;
              if (shouldForceAdvertisementRefresh ||
                  _iosNetworkUnavailable ||
                  currentHost != network.address ||
                  _hostInterfaceName != network.interfaceName ||
                  _hostNetworkKind != network.kind) {
                if (shouldForceAdvertisementRefresh) {
                  debugPrint('[LinkNest] iOS 发起者后台恢复，强制重新注册局域网空间广告');
                }
                await _server.refreshNetworkAddresses(
                  selectedAddress: network.address,
                  selectedInterface: network.interfaceName,
                );
                _url = _server.inviteUrl;
                _urls = _server.inviteUrls;
                debugPrint('[LinkNest] iOS 发起者共享地址已更新');
                _forceAdvertisementRefreshPending = false;
              }
              _iosNetworkUnavailable = false;
              _hostNetworkKind = network.kind;
              _hostInterfaceName = network.interfaceName;
              _hotspotNotice = null;
            }
          } catch (error) {
            _forceAdvertisementRefreshPending = false;
            _hotspotNotice = '局域网地址发生变化，但共享服务尚未恢复。请检查网络后重试。';
            debugPrint('[LinkNest] iOS 共享地址检查失败 reason=${error.runtimeType}');
          }
        }
      }

      if (Platform.isAndroid &&
          (force ||
              _lastNotificationOnlineCount != onlineCount ||
              _lastNotificationSpaceName != spaceName.value)) {
        try {
          await _native.updateHostForegroundService(
            spaceName: spaceName.value,
            onlineCount: onlineCount,
          );
          _lastNotificationOnlineCount = onlineCount;
          _lastNotificationSpaceName = spaceName.value;
        } catch (error) {
          debugPrint('[LinkNest] 更新发起者通知失败 reason=${error.runtimeType}');
        }
      }

      if (force ||
          _lastPowerCheckAt == null ||
          now.difference(_lastPowerCheckAt!) >= const Duration(seconds: 30)) {
        _lastPowerCheckAt = now;
        try {
          final power = await _native.getPowerState();
          _powerNotice = HostHealthPolicy.powerNotice(power);
        } catch (error) {
          debugPrint('[LinkNest] 读取电源状态失败 reason=${error.runtimeType}');
        }
      }

      if (Platform.isAndroid &&
          (force ||
              _lastHotspotCheckAt == null ||
              now.difference(_lastHotspotCheckAt!) >=
                  const Duration(seconds: 15))) {
        _lastHotspotCheckAt = now;
        try {
          final hotspot = await _native.getHotspotInfo();
          final stopped =
              hotspot['supported'] == true &&
              (hotspot['running'] != true ||
                  (hotspot['ssid']?.toString().isEmpty ?? true));
          if (stopped) {
            if (!_hotspotRecoveryAttempted && !_hotspotRecoveryInFlight) {
              unawaited(_recoverAndroidHotspot(automatic: true));
            } else if (!_hotspotRecoveryInFlight) {
              _hotspotNotice = 'Android 临时热点已经停止。请点“重试热点”；系统可能生成新的名称和密码。';
              _hotspotManualRetryAvailable = true;
              _showHotspotSnackBar(
                _hotspotNotice!,
                persistent: true,
                allowRetry: true,
              );
            }
          } else if (!_hotspotRecoveryInFlight) {
            _hotspotNotice = null;
            _hotspotManualRetryAvailable = false;
          }
        } catch (error) {
          debugPrint(
            '[LinkNest] 刷新 Android 热点状态失败 reason=${error.runtimeType}',
          );
        }
      }

      if (!mounted || _operation != _SpaceOperation.running) return;
      setState(() {
        _onlineCount = onlineCount;
        _hostNotice = _visibleHostNotice();
      });
    } finally {
      _healthCheckInFlight = false;
      if (_operation != _SpaceOperation.running) {
        _forceAdvertisementRefreshPending = false;
      }
      if (_forceAdvertisementRefreshPending &&
          mounted &&
          _operation == _SpaceOperation.running) {
        unawaited(_refreshHostHealth(force: true));
      }
    }
  }

  void _handleNativeHotspotState(NativeHotspotState state) {
    final hotspotUptime = _hotspotStartedAt == null
        ? null
        : DateTime.now().difference(_hotspotStartedAt!).inSeconds;
    final likelyIdleTimeout =
        state.state == 'stopped' &&
        _onlineCount == 0 &&
        hotspotUptime != null &&
        hotspotUptime >= const Duration(minutes: 9).inSeconds &&
        hotspotUptime <= const Duration(minutes: 12).inSeconds;
    debugPrint(
      '[LinkNest] 收到发起者热点状态 state=${state.state} '
      'unexpected=${state.unexpected} reasonPresent=${state.reason != null} '
      'operation=${_operation.name} onlineCount=$_onlineCount '
      'uptimeSeconds=${hotspotUptime ?? -1} '
      'likelyIdleTimeout=$likelyIdleTimeout',
    );
    if (!state.unexpected || state.state == 'started') {
      return;
    }
    if (_operation != _SpaceOperation.running) {
      debugPrint('[LinkNest] 空间未运行，忽略发起者热点停止回调');
      return;
    }
    if (!_hotspotRecoveryAttempted && !_hotspotRecoveryInFlight) {
      unawaited(_recoverAndroidHotspot(automatic: true));
      return;
    }
    _hotspotNotice = 'Android 临时热点已经停止。请点“重试热点”；系统可能生成新的名称和密码。';
    _hotspotManualRetryAvailable = true;
    _dismissedHostNotice = null;
    _publishHostNotice();
    _showHotspotSnackBar(_hotspotNotice!, persistent: true, allowRetry: true);
  }

  Future<void> _recoverAndroidHotspot({required bool automatic}) async {
    if (!Platform.isAndroid ||
        _operation != _SpaceOperation.running ||
        _hotspotRecoveryInFlight) {
      return;
    }
    _hotspotRecoveryInFlight = true;
    _hotspotRecoveryAttempted = true;
    _hotspotManualRetryAvailable = false;
    _hotspotNotice = automatic ? '检测到临时热点已停止，正在自动恢复…' : '正在重新启动临时热点…';
    _dismissedHostNotice = null;
    _publishHostNotice();
    _showHotspotSnackBar(_hotspotNotice!);
    debugPrint('[LinkNest] 开始恢复发起者热点 automatic=$automatic');
    try {
      if (automatic) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (!mounted || _operation != _SpaceOperation.running) return;
      }
      final hotspot = await _native.startHotspot().timeout(
        const Duration(seconds: 15),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      HostNetwork? network;
      for (var attempt = 0; attempt < 10 && network == null; attempt++) {
        network = selectAndroidHotspotNetwork(
          await _native.getLocalAddresses(),
        );
        if (network == null) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      if (network == null) throw StateError('热点恢复后没有可用的局域网地址');
      await _server.refreshNetworkAddresses(
        selectedAddress: network.address,
        selectedInterface: network.interfaceName,
      );
      if (!mounted || _operation != _SpaceOperation.running) return;
      setState(() {
        _ssid = hotspot['ssid']?.toString() ?? '';
        _wifiPassword = hotspot['password']?.toString() ?? '';
        _url = _server.inviteUrl;
        _urls = _server.inviteUrls;
        _lastHotspotCheckAt = DateTime.now();
        _hotspotStartedAt = DateTime.now();
        _hotspotNotice = '临时热点已恢复。若热点名称或密码发生变化，访客重新连接新热点后可在空间内点“重新连接”。';
        _hotspotManualRetryAvailable = false;
        _dismissedHostNotice = null;
        _hostNotice = _visibleHostNotice();
      });
      _showHotspotSnackBar(_hotspotNotice!);
      debugPrint('[LinkNest] 发起者热点恢复成功');
    } catch (error) {
      debugPrint('[LinkNest] 发起者热点恢复失败 reason=${error.runtimeType}');
      if (!mounted || _operation != _SpaceOperation.running) return;
      _hotspotNotice = '临时热点恢复失败。请确认系统 Wi-Fi 状态后点“重试热点”，或关闭空间后重新共享。';
      _hotspotManualRetryAvailable = true;
      _dismissedHostNotice = null;
      _publishHostNotice();
      _showHotspotSnackBar(_hotspotNotice!, persistent: true, allowRetry: true);
    } finally {
      _hotspotRecoveryInFlight = false;
    }
  }

  String? _composeHostNotice() {
    final messages = [
      _notificationNotice,
      _lifecycleNotice,
      _idleNotice,
      _powerNotice,
      _hotspotNotice,
    ].whereType<String>().where((message) => message.isNotEmpty).toList();
    return messages.isEmpty ? null : messages.join('\n');
  }

  void _publishHostNotice() {
    if (!mounted) return;
    setState(() {
      _hostNotice = _visibleHostNotice();
    });
  }

  void _showHotspotSnackBar(
    String message, {
    bool persistent = false,
    bool allowRetry = false,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _operation != _SpaceOperation.running) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) {
        debugPrint('[LinkNest] 当前页面不支持显示热点全局提示');
        return;
      }
      if (_lastHotspotSnackMessage == message) return;
      _lastHotspotSnackMessage = message;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            duration: persistent
                ? const Duration(days: 1)
                : const Duration(seconds: 8),
            behavior: SnackBarBehavior.floating,
            action: allowRetry
                ? SnackBarAction(
                    label: '重试热点',
                    onPressed: () {
                      unawaited(_recoverAndroidHotspot(automatic: false));
                    },
                  )
                : null,
          ),
        );
      debugPrint(
        '[LinkNest] 已显示发起者热点全局提示 '
        'persistent=$persistent retry=$allowRetry',
      );
    });
  }

  String? _visibleHostNotice() {
    final notice = _composeHostNotice();
    if (notice != _lastComposedHostNotice) {
      _lastComposedHostNotice = notice;
      _dismissedHostNotice = null;
    }
    return notice == _dismissedHostNotice ? null : notice;
  }

  void _dismissHostNotice() {
    if (_hostNotice == null) return;
    setState(() {
      _dismissedHostNotice = _hostNotice;
      _hostNotice = null;
    });
  }

  void _clearHostHealthState() {
    _sharingStartedAt = null;
    _hotspotStartedAt = null;
    _lastVisitorSeenAt = null;
    _lastPowerCheckAt = null;
    _lastNetworkCheckAt = null;
    _lastHotspotCheckAt = null;
    _hotspotRecoveryInFlight = false;
    _hotspotRecoveryAttempted = false;
    _hotspotManualRetryAvailable = false;
    _lastNotificationOnlineCount = -1;
    _lastNotificationSpaceName = '';
    _notificationNotice = null;
    _lifecycleNotice = null;
    _idleNotice = null;
    _powerNotice = null;
    _hotspotNotice = null;
    _lastHotspotSnackMessage = null;
    _hostNotice = null;
    _dismissedHostNotice = null;
    _lastComposedHostNotice = null;
    _hostNetworkKind = null;
    _hostInterfaceName = null;
    _iosNetworkUnavailable = false;
    _iosWasBackgrounded = false;
  }

  Future<void> _showClients() async {
    final clients = _server.clients;
    await showLinkNestDialog<void>(
      context: context,
      builder: (context) => LinkNestDialog(
        title: '在线成员',
        actions: [
          LinkNestButton(
            onPressed: () => popLinkNest(context),
            label: '关闭',
            variant: FButtonVariant.secondary,
          ),
        ],
        child: clients.isEmpty
            ? const Text('暂无访客连接')
            : SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final c in clients)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.person_outline, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(c['name']?.toString() ?? '未知'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: !_awaitingInitialStart && _operation == _SpaceOperation.idle,
      onPopInvokedWithResult: _handleBlockedBack,
      child: LinkNestContentTransition(
        child: _phase == _SpacePhase.idle
            ? KeyedSubtree(
                key: const ValueKey('startup-overlay'),
                child: _buildStartupOverlay(),
              )
            : Scaffold(
                key: const ValueKey('running-space'),
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    LinkNestTabStack(
                      index: _currentTab,
                      children: [
                        LinkNestContentTransition(
                          child: KeyedSubtree(
                            key: ValueKey(_phase),
                            child: _buildSpacePage(),
                          ),
                        ),
                        SettingsPage(
                          url: _url,
                          alternativeUrls: _urls,
                          ssid: _ssid,
                          wifiPassword: _wifiPassword,
                          running: _operation == _SpaceOperation.running,
                          onSpaceNameChanged:
                              _operation == _SpaceOperation.running
                              ? _renameActiveSpace
                              : null,
                        ),
                      ],
                    ),
                    LinkNestContentTransition(
                      child: _operation == _SpaceOperation.stopping
                          ? const Stack(
                              key: ValueKey('stopping'),
                              fit: StackFit.expand,
                              children: [
                                ModalBarrier(
                                  dismissible: false,
                                  color: Colors.black54,
                                ),
                                _CreatingSpaceDialog(label: '正在关闭空间'),
                              ],
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('not-stopping'),
                            ),
                    ),
                  ],
                ),
                bottomNavigationBar: _phase == _SpacePhase.idle
                    ? null
                    : FBottomNavigationBar(
                        style: .delta(
                          decoration: .value(
                            BoxDecoration(
                              color: context.theme.colors.background,
                            ),
                          ),
                        ),
                        index: _currentTab,
                        safeAreaBottom: true,
                        onChange: (index) =>
                            setState(() => _currentTab = index),
                        children: const [
                          FBottomNavigationBarItem(
                            icon: Icon(FLucideIcons.folder),
                            label: Text('空间'),
                          ),
                          FBottomNavigationBarItem(
                            icon: Icon(FLucideIcons.settings),
                            label: Text('设置'),
                          ),
                        ],
                      ),
              ),
      ),
    );
  }

  Widget _buildSpacePage() {
    switch (_phase) {
      case _SpacePhase.idle:
        return const SizedBox.shrink();
      case _SpacePhase.guide:
        return _buildGuidePage();
      case _SpacePhase.active:
        return _buildSharingPage();
    }
  }

  Widget _buildStartupOverlay() {
    final starting =
        _awaitingInitialStart || _operation == _SpaceOperation.starting;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ModalBarrier(dismissible: false, color: Colors.black54),
        SafeArea(
          child: LinkNestDialogTransition(
            animation:
                ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation,
            // 整条路由已经负责淡入；这里只负责弹窗尺寸和内部状态衔接。
            fade: false,
            child: LinkNestContentTransition(
              child: _awaitingName
                  ? CreateSpaceNameDialog(
                      key: const ValueKey('name'),
                      onConfirmed: _confirmName,
                    )
                  : starting
                  ? const _CreatingSpaceDialog(key: ValueKey('waiting'))
                  : LinkNestDialog(
                      key: const ValueKey('failed'),
                      title: _existingSpaces.isEmpty ? '创建未完成' : '发现运行中的空间',
                      actions: [
                        if (_existingSpaces.isEmpty)
                          LinkNestButton(label: '重试', onPressed: _start),
                        LinkNestButton(
                          label: '返回首页',
                          variant: FButtonVariant.secondary,
                          onPressed: () => popLinkNest(context),
                        ),
                      ],
                      child: _existingSpaces.isEmpty
                          ? Text(_status)
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(_status),
                                const SizedBox(height: 12),
                                for (final space in _existingSpaces)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: LinkNestButton(
                                      label: '进入 ${space.name}',
                                      onPressed: () =>
                                          _joinExistingSpace(space),
                                    ),
                                  ),
                              ],
                            ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _hostExitButton({double iconSize = 22}) => CloseSpaceButton(
    iconSize: iconSize,
    enabled: _operation == _SpaceOperation.running,
    onPressed: _requestCloseSpace,
    onForceClose: _requestForceCloseSpace,
  );

  Widget _buildGuidePage() => Scaffold(
    backgroundColor: context.theme.colors.background,
    body: SafeArea(
      child: Column(
        children: [
          LinkNestHeaderRow(
            key: const ValueKey('qr-header'),
            sideWidth: 92,
            leading: _hostExitButton(iconSize: 28),
            title: ValueListenableBuilder<String>(
              valueListenable: spaceName,
              builder: (context, name, _) => Text(
                name,
                maxLines: 1,
                softWrap: false,
                style: context.theme.typography.body.lg.copyWith(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            trailing: FButton(
              key: const ValueKey('qr-enter'),
              variant: FButtonVariant.ghost,
              style: .delta(
                contentStyle: .delta(
                  padding: .value(
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                ),
              ),
              onPress: _operation == _SpaceOperation.running
                  ? () => setState(() {
                      debugPrint('[LinkNest] 从二维码引导进入空间');
                      _phase = _SpacePhase.active;
                    })
                  : null,
              child: const Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '进入空间',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_hostNotice != null) ...[
                        _buildHostNoticeBanner(),
                        const SizedBox(height: 8),
                      ],
                      if (_iosNetworkUnavailable)
                        const LinkNestNotice(
                          message: '当前网络暂时无法共享。请检查个人热点或 Wi-Fi，恢复后会自动更新空间二维码。',
                        )
                      else
                        QrCodesSection(
                          url: _url,
                          alternativeUrls: _urls,
                          ssid: _ssid,
                          wifiPassword: _wifiPassword,
                          networkLabel: switch (_hostNetworkKind) {
                            HostNetworkKind.iosWifi ||
                            HostNetworkKind.androidWifi => 'Wi-Fi 名称',
                            HostNetworkKind.manualHotspot => '热点名称',
                            _ => '本机热点名称',
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildSharingPage() => SpaceGalleryScreen(
    dataSource: _hostDataSource,
    native: _native,
    header: _hostNotice == null ? null : _buildHostNoticeBanner(),
    closeDataSourceOnDispose: false,
    automaticallyImplyLeading: false,
    exitAction: _hostExitButton(),
    statusLine: LinkNestAction(
      key: const ValueKey('host-online'),
      onPressed: _showClients,
      icon: FLucideIcons.users,
      label: '$_onlineCount',
    ),
  );

  Widget _buildHostNoticeBanner() {
    return LinkNestNotice(
      message: _hostNotice ?? '',
      actions: [
        if (_hotspotManualRetryAvailable)
          LinkNestAction(
            onPressed: _hotspotRecoveryInFlight
                ? null
                : () => _recoverAndroidHotspot(automatic: false),
            label: '重试热点',
          ),
        LinkNestAction(onPressed: _dismissHostNotice, label: '知道了'),
      ],
    );
  }
}

class CloseSpaceButton extends StatefulWidget {
  const CloseSpaceButton({
    super.key,
    required this.enabled,
    required this.onPressed,
    required this.onForceClose,
    this.iconSize = 22,
  });

  final bool enabled;
  final double iconSize;
  final VoidCallback onPressed;
  final VoidCallback onForceClose;

  @override
  State<CloseSpaceButton> createState() => _CloseSpaceButtonState();
}

class _CloseSpaceButtonState extends State<CloseSpaceButton> {
  static const _forceDuration = Duration(seconds: 5);
  static const _hintDelay = Duration(milliseconds: 600);

  Timer? _forceTimer;
  Timer? _hintTimer;
  bool _holding = false;
  bool _forceTriggered = false;
  bool _longHoldRecognized = false;

  @override
  void didUpdateWidget(covariant CloseSpaceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _forceTimer?.cancel();
      _forceTimer = null;
      _hintTimer?.cancel();
      _hintTimer = null;
      _holding = false;
    }
  }

  @override
  void dispose() {
    _forceTimer?.cancel();
    _hintTimer?.cancel();
    super.dispose();
  }

  void _startHold(TapDownDetails _) {
    if (!widget.enabled || _holding) return;
    _forceTriggered = false;
    _longHoldRecognized = false;
    setState(() => _holding = true);
    debugPrint('[LinkNest] 开始长按强制关闭空间');
    _hintTimer = Timer(_hintDelay, () {
      if (!mounted || !_holding) return;
      _longHoldRecognized = true;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('继续按住，满 5 秒后可强制关闭空间。')));
    });
    _forceTimer = Timer(_forceDuration, () {
      if (!mounted || !_holding || !widget.enabled) return;
      _forceTriggered = true;
      _holding = false;
      debugPrint('[LinkNest] 长按强制关闭空间计时完成');
      unawaited(HapticFeedback.heavyImpact());
      setState(() {});
      widget.onForceClose();
    });
  }

  void _finishTap(TapUpDetails _) {
    final forceTriggered = _forceTriggered;
    final shouldRunNormalClose = !forceTriggered && !_longHoldRecognized;
    _cancelHold();
    if (shouldRunNormalClose && widget.enabled) widget.onPressed();
  }

  void _cancelHold() {
    _forceTimer?.cancel();
    _forceTimer = null;
    _hintTimer?.cancel();
    _hintTimer = null;
    if (!_holding) return;
    _holding = false;
    debugPrint('[LinkNest] 已取消长按强制关闭空间');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.enabled
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).disabledColor;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: '退出空间',
      hint: '关闭当前共享；持续按住 5 秒可强制关闭',
      onTap: widget.enabled ? widget.onPressed : null,
      child: GestureDetector(
        key: const ValueKey('host-exit'),
        excludeFromSemantics: true,
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.enabled ? _startHold : null,
        onTapUp: widget.enabled ? _finishTap : null,
        onTapCancel: _cancelHold,
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _holding ? context.theme.colors.secondary : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(FLucideIcons.logOut, size: widget.iconSize, color: color),
        ),
      ),
    );
  }
}
