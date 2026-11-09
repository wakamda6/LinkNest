import 'package:linknest/app_theme.dart';
import 'package:linknest/app_ui.dart';
import 'package:forui/forui.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/file_record.dart';
import 'package:linknest/native.dart';
import 'package:linknest/space_data_source.dart';
import 'package:linknest/space_gallery.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:video_player/video_player.dart';

final Uint8List _testImageBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEklEQVR4nGP4z8DwHwwZ/kMAAFDBCvY8uPBWAAAAAElFTkSuQmCC',
);

void main() {
  test('gallery font files and licenses are available offline', () async {
    for (final name in ['Lora', 'Raleway']) {
      expect(
        (await rootBundle.load('assets/fonts/$name.ttf')).lengthInBytes,
        greaterThan(100000),
      );
      expect(
        await rootBundle.loadString('assets/fonts/$name-OFL.txt'),
        contains('SIL OPEN FONT LICENSE'),
      );
    }
  });

  testWidgets('compact gallery and viewer show legible actions and fonts', (
    tester,
  ) async {
    final source = _FakeGuestDataSource(
      files: [
        _record(id: 'first'),
        _record(id: 'second'),
      ],
    );
    await tester.pumpWidget(
      _galleryApp(
        SpaceGalleryScreen(
          dataSource: source,
          native: LinkNestNative(),
          guestMode: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('排序与显示选项'), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-options')), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-multiselect')), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const ValueKey('gallery-options'))).dy,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('gallery-multiselect'))).dy,
        1,
      ),
    );
    expect(
      tester.widget<Text>(find.text('周末旅行')).style?.fontFamily,
      'LinkNestLora',
    );
    await tester.tap(find.byKey(const ValueKey('first')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('保存到相册'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('1 / 2')).style?.fontFamily,
      'LinkNestRaleway',
    );
    expect(find.byTooltip('关闭预览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery options stay usable on narrow large-text screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previousTheme = themeModeNotifier.value;
    addTearDown(() => themeModeNotifier.value = previousTheme);
    await tester.pumpWidget(
      _galleryApp(
        SpaceGalleryScreen(
          dataSource: _FakeGuestDataSource(files: [_record(id: 'one')]),
          native: LinkNestNative(),
          guestMode: true,
        ),
        scale: 1.8,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gallery-options')));
    await tester.pumpAndSettle();
    expect(find.text('画廊显示'), findsOneWidget);
    await tester.ensureVisible(find.text('深色'));
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(themeModeNotifier.value, ThemeMode.dark);
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewer controls fit a narrow large-text screen', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _galleryApp(
        SpaceGalleryScreen(
          dataSource: _FakeGuestDataSource(files: [_record(id: 'one')]),
          native: LinkNestNative(),
          guestMode: true,
        ),
        scale: 1.8,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('one')));
    await tester.pumpAndSettle();
    expect(find.text('保存到相册'), findsOneWidget);
    expect(find.text('1 / 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final guestMode in [false, true]) {
    testWidgets(
      'REQ-1203 own uploads last in gallery and viewer (guest=$guestMode)',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = _FakeGuestDataSource(
          uploaderId: 'me',
          files: [
            _record(
              id: 'mine-new',
              uploaderId: 'me',
              uploadedAt: DateTime(2026, 9, 27),
            ),
            _record(
              id: 'mine-old',
              uploaderId: 'me',
              uploadedAt: DateTime(2026, 9, 25),
            ),
            _record(
              id: 'other',
              uploaderId: 'other',
              uploadedAt: DateTime(2026, 9, 24),
            ),
            _record(id: 'legacy', uploadedAt: DateTime(2026, 9, 23)),
          ],
        );
        await tester.pumpWidget(
          _galleryApp(
            SpaceGalleryScreen(
              dataSource: source,
              native: LinkNestNative(),
              guestMode: guestMode,
            ),
          ),
        );
        await tester.pumpAndSettle();
        Offset point(String key) =>
            tester.getTopLeft(find.byKey(ValueKey(key)));
        expect(find.text('我上传的'), findsOneWidget);
        expect(point('other').dy, lessThan(point('mine-new').dy));
        expect(point('legacy').dy, lessThan(point('mine-new').dy));
        expect(point('mine-new').dx, lessThan(point('mine-old').dx));
        await tester.tap(find.byKey(const ValueKey('mine-new')));
        await tester.pumpAndSettle();
        final viewer = tester.widget<PhotoViewGallery>(
          find.byType(PhotoViewGallery),
        );
        expect(viewer.pageController!.initialPage, 2);
        Navigator.of(tester.element(find.byType(PhotoViewGallery))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('gallery-options')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('最旧优先').last);
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel('关闭画廊选项'));
        await tester.pumpAndSettle();
        expect(point('mine-old').dx, lessThan(point('mine-new').dx));
        expect(point('legacy').dy, lessThan(point('mine-old').dy));
        await tester.tap(find.byKey(const ValueKey('gallery-options')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('上传者').last);
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel('关闭画廊选项'));
        await tester.pumpAndSettle();
        // All names are deliberately identical; reliable IDs must remain distinct.
        expect(find.byKey(const ValueKey('legacy:快乐海豚')), findsOneWidget);
        expect(point('id:other').dy, lessThan(point('id:me').dy));
        await tester.tapAt(point('id:other') + const Offset(24, 24));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('other')), findsOneWidget);
        expect(find.byKey(const ValueKey('mine-new')), findsNothing);
        expect(find.text('我上传的'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
  }
  testWidgets('REQ-1203 single ownership category has no divider', (
    tester,
  ) async {
    final source = _FakeGuestDataSource(
      uploaderId: 'me',
      files: [_record(id: 'mine', uploaderId: 'me')],
    );
    await tester.pumpWidget(
      _galleryApp(
        SpaceGalleryScreen(
          dataSource: source,
          native: LinkNestNative(),
          guestMode: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('我上传的'), findsNothing);
    source.files = [_record(id: 'legacy')];
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('legacy')), findsOneWidget);
    expect(find.text('我上传的'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('Guest gallery shows identity and explicit actions', (
    tester,
  ) async {
    final dataSource = _FakeGuestDataSource(interruptedUpload: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: linkNestLightTheme,
        localizationsDelegates: linkNestLocalizations,
        supportedLocales: const [Locale('zh'), Locale('en')],
        locale: const Locale('zh'),
        builder: (_, child) => LinkNestTheme(child: child!),
        home: SpaceGalleryScreen(
          dataSource: dataSource,
          native: LinkNestNative(),
          guestMode: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('周末旅行'), findsOneWidget);
    expect(find.text('快乐海豚'), findsOneWidget);
    expect(find.byKey(const ValueKey('guest-exit')), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-upload')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('guest-exit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('退出空间？'), findsOneWidget);
    expect(find.textContaining('正在进行或等待重试的上传'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Guest gallery aligns header names with action icons', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const spaceName = '这是一个需要完整显示的家庭旅行空间';
    const participantName = '无忧的蒲公英';
    final dataSource = _FakeGuestDataSource(
      name: spaceName,
      participant: participantName,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: linkNestLightTheme,
        localizationsDelegates: linkNestLocalizations,
        supportedLocales: const [Locale('zh'), Locale('en')],
        locale: const Locale('zh'),
        builder: (_, child) => LinkNestTheme(child: child!),
        home: SpaceGalleryScreen(
          dataSource: dataSource,
          native: LinkNestNative(),
          guestMode: true,
        ),
      ),
    );
    await tester.pump();

    final spaceText = find.text(spaceName);
    final participantText = find.text(participantName);
    final exit = find.byKey(const ValueKey('guest-exit'));
    final upload = find.byKey(const ValueKey('gallery-upload'));
    expect(
      tester.getCenter(spaceText).dy,
      closeTo(tester.getCenter(participantText).dy, 1),
    );
    expect(
      tester.getCenter(spaceText).dx,
      lessThan(tester.getCenter(participantText).dx),
    );
    final options = find.byKey(const ValueKey('gallery-options'));
    final multiSelect = find.byKey(const ValueKey('gallery-multiselect'));
    expect(
      tester.getCenter(participantText).dx,
      greaterThan(tester.getCenter(spaceText).dx),
    );
    expect(
      tester.getCenter(participantText).dy,
      lessThan(tester.getCenter(options).dy),
    );
    expect(
      tester.getCenter(options).dy,
      closeTo(tester.getCenter(multiSelect).dy, 1),
    );
    expect(options.hitTestable(), findsOneWidget);
    expect(multiSelect.hitTestable(), findsOneWidget);
    expect(tester.getCenter(exit).dy, closeTo(tester.getCenter(upload).dy, 1));
    expect(
      tester.getCenter(exit).dy,
      greaterThan(tester.getCenter(spaceText).dy),
    );
    expect(find.byIcon(FLucideIcons.imagePlus), findsOneWidget);
    expect(
      tester.getCenter(exit).dx,
      lessThan(tester.getCenter(participantText).dx),
    );
    expect(tester.getCenter(upload).dx, lessThan(tester.getCenter(options).dx));
    expect(exit.hitTestable(), findsOneWidget);
    expect(upload.hitTestable(), findsOneWidget);

    expect(spaceText, findsOneWidget);
    expect(participantText, findsOneWidget);
    final title = tester.widget<Text>(spaceText);
    final deviceName = tester.widget<Text>(participantText);
    expect(title.style?.fontSize, 20);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(title.style!.fontSize!, greaterThan(deviceName.style!.fontSize!));
    expect(
      find.ancestor(of: spaceText, matching: find.byType(FittedBox)),
      findsNothing,
    );
    expect(
      find.ancestor(of: participantText, matching: find.byType(FittedBox)),
      findsOneWidget,
    );
    final exitIcon = find.descendant(
      of: exit,
      matching: find.byIcon(FLucideIcons.logOut),
    );
    expect(
      tester.getTopLeft(spaceText).dx,
      closeTo(tester.getTopLeft(exitIcon).dx, 2),
    );
    final lastActionIcon = find.descendant(
      of: multiSelect,
      matching: find.byIcon(FLucideIcons.listChecks),
    );
    expect(
      tester.getTopRight(participantText).dx,
      closeTo(tester.getTopRight(lastActionIcon).dx, 2),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Guest gallery pauses polling and reconnects after resume', (
    tester,
  ) async {
    const channel = MethodChannel('linknest/native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getLocalAddresses') {
            return [
              {'interface': 'wlan0', 'address': '192.168.1.2'},
            ];
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final dataSource = _FakeGuestDataSource(interruptedUpload: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: linkNestLightTheme,
        localizationsDelegates: linkNestLocalizations,
        supportedLocales: const [Locale('zh'), Locale('en')],
        locale: const Locale('zh'),
        builder: (_, child) => LinkNestTheme(child: child!),
        home: SpaceGalleryScreen(
          dataSource: dataSource,
          native: LinkNestNative(),
          guestMode: true,
        ),
      ),
    );
    await tester.pump();
    final initialLists = dataSource.listCalls;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 4));
    expect(dataSource.listCalls, initialLists);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(dataSource.reconnectCalls, 1);
    expect(dataSource.listCalls, greaterThan(initialLists));
    expect(dataSource.retryCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Gallery reloads only a changed preview record', (tester) async {
    final dataSource = _FakeGuestDataSource(
      files: [_record(id: 'photo-1', previewStatus: PreviewStatus.failed)],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: linkNestLightTheme,
        localizationsDelegates: linkNestLocalizations,
        supportedLocales: const [Locale('zh'), Locale('en')],
        locale: const Locale('zh'),
        builder: (_, child) => LinkNestTheme(child: child!),
        home: SpaceGalleryScreen(
          dataSource: dataSource,
          native: LinkNestNative(),
          closeDataSourceOnDispose: false,
        ),
      ),
    );
    await tester.pump();
    expect(dataSource.thumbnailCalls, 0);

    dataSource.files = [
      _record(id: 'photo-1', previewStatus: PreviewStatus.ready),
    ];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(dataSource.thumbnailCalls, 1);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(dataSource.thumbnailCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'Image viewer prioritizes pinch, rebounds, and ignores image taps',
    (tester) async {
      final dataSource = _FakeGuestDataSource(
        files: [
          _record(id: 'photo-1', previewStatus: PreviewStatus.ready),
          _record(id: 'photo-2', previewStatus: PreviewStatus.ready),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: linkNestLightTheme,
          localizationsDelegates: linkNestLocalizations,
          supportedLocales: const [Locale('zh'), Locale('en')],
          locale: const Locale('zh'),
          builder: (_, child) => LinkNestTheme(child: child!),
          home: SpaceGalleryScreen(
            dataSource: dataSource,
            native: LinkNestNative(),
            closeDataSourceOnDispose: false,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('photo-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final backdrop = find.byKey(const ValueKey('viewer-backdrop'));
      expect(
        tester.widget<FadeTransition>(backdrop).opacity.value,
        allOf(greaterThan(0), lessThan(1)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PhotoViewGallery), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(find.byTooltip('关闭预览'), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      final viewerFinder = find.byType(PhotoView).first;
      final rect = tester.getRect(viewerFinder);
      final focalPoint = Offset(
        rect.left + rect.width * 0.25,
        rect.top + rect.height * 0.3,
      );
      final first = await tester.startGesture(
        focalPoint - const Offset(20, 0),
        pointer: 11,
      );
      final second = await tester.startGesture(
        focalPoint + const Offset(20, 0),
        pointer: 12,
      );
      await tester.pump();
      await first.moveTo(focalPoint - const Offset(100, 0));
      await second.moveTo(focalPoint + const Offset(100, 0));
      await tester.pump();
      final photoView = tester.widget<PhotoView>(viewerFinder);
      expect(photoView.controller!.scale, greaterThan(1));
      final gallery = tester.widget<PhotoViewGallery>(
        find.byType(PhotoViewGallery),
      );
      expect(gallery.pageController!.page, closeTo(0, 0.01));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();

      await tester.tapAt(focalPoint);
      await tester.pump();
      expect(find.byTooltip('关闭预览'), findsOneWidget);

      photoView.controller!.reset();
      await tester.pumpAndSettle();
      expect(photoView.controller!.scale, closeTo(1, 0.01));

      final shrinkFirst = await tester.startGesture(
        focalPoint - const Offset(100, 0),
        pointer: 13,
      );
      final shrinkSecond = await tester.startGesture(
        focalPoint + const Offset(100, 0),
        pointer: 14,
      );
      await tester.pump();
      await shrinkFirst.moveTo(focalPoint - const Offset(20, 0));
      await shrinkSecond.moveTo(focalPoint + const Offset(20, 0));
      await tester.pump();
      await shrinkFirst.up();
      await shrinkSecond.up();
      await tester.pumpAndSettle();
      expect(photoView.controller!.scale, closeTo(1, 0.01));

      await tester.drag(find.byType(PhotoViewGallery), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(gallery.pageController!.page, closeTo(1, 0.01));

      await tester.tap(find.byTooltip('关闭预览'));
      await tester.pump(); // 关闭逻辑先复位图片，再于帧末请求返回。
      await tester.pump(); // 启动路由退出的首帧。
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PhotoViewGallery), findsOneWidget);
      expect(
        tester.widget<FadeTransition>(backdrop).opacity.value,
        allOf(greaterThan(0), lessThan(1)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewGallery), findsNothing);
      expect(find.byKey(const ValueKey('photo-2')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('Host plays a guest-uploaded video from its local original', (
    tester,
  ) async {
    final controllers = <_FakeVideoPlayerController>[];
    final paths = <String>[];
    final source = _FakeGuestDataSource(
      allowMaterialize: true,
      files: [
        _record(
          id: 'guest-video',
          name: 'clip.mp4',
          kind: 'video',
          mimeType: 'video/mp4',
          previewStatus: PreviewStatus.ready,
        ),
        _record(id: 'photo'),
      ],
    );
    await tester.pumpWidget(
      _galleryApp(
        SpaceGalleryScreen(
          dataSource: source,
          native: LinkNestNative(),
          guestMode: false,
          closeDataSourceOnDispose: false,
          localVideoControllerFactory: (file) {
            paths.add(file.path);
            final controller = _FakeVideoPlayerController();
            controllers.add(controller);
            return controller;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('guest-video')));
    await tester.pumpAndSettle();
    expect(find.text('播放视频'), findsOneWidget);
    expect(source.materializeCalls, 0);

    await tester.tap(find.text('播放视频'));
    await tester.pumpAndSettle();
    expect(paths, ['test/guest-video.mp4']);
    expect(source.materializeCalls, 1);
    expect(controllers.single.playCalls, 1);

    controllers.single.completePlayback();
    await tester.pump();
    await tester.tap(find.byTooltip('重新播放'));
    await tester.pump();
    expect(controllers.single.playCalls, 2);

    await tester.drag(find.byType(PhotoViewGallery), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(controllers.single.value.isPlaying, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(controllers.single.disposed, isTrue);
  });

  testWidgets(
    'Guest video streams on demand, replays, and reuses its session',
    (tester) async {
      final createdControllers = <_FakeVideoPlayerController>[];
      final createdSources = <NetworkVideoPlaybackSource>[];
      final dataSource = _FakeGuestDataSource(
        files: [
          _record(
            id: 'video-1',
            name: 'clip.mp4',
            kind: 'video',
            mimeType: 'video/mp4',
            previewStatus: PreviewStatus.ready,
          ),
          _record(
            id: 'video-2',
            name: 'second.mp4',
            kind: 'video',
            mimeType: 'video/mp4',
            previewStatus: PreviewStatus.ready,
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: linkNestLightTheme,
          localizationsDelegates: linkNestLocalizations,
          supportedLocales: const [Locale('zh'), Locale('en')],
          locale: const Locale('zh'),
          builder: (_, child) => LinkNestTheme(child: child!),
          home: SpaceGalleryScreen(
            dataSource: dataSource,
            native: LinkNestNative(),
            closeDataSourceOnDispose: false,
            guestMode: true,
            videoControllerFactory: (source) {
              createdSources.add(source);
              final controller = _FakeVideoPlayerController();
              createdControllers.add(controller);
              return controller;
            },
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('video-1')));
      await tester.pumpAndSettle();

      expect(find.text('在线播放'), findsOneWidget);
      expect(
        tester.element(find.text('在线播放')).theme.colors.brightness,
        Brightness.dark,
      );
      expect(
        find.ancestor(
          of: find.text('在线播放'),
          matching: find.byType(LinkNestButton),
        ),
        findsOneWidget,
      );
      expect(find.text('下载后播放'), findsNothing);
      expect(dataSource.materializeCalls, 0);

      await tester.tap(find.text('在线播放'));
      await tester.pumpAndSettle();
      expect(createdControllers, hasLength(1));
      expect(createdSources.single.uri.host, '192.168.43.1');
      expect(
        createdSources.single.uri.host,
        isNot(anyOf('127.0.0.1', 'localhost', '::1')),
      );
      expect(createdControllers.single.playCalls, 1);
      expect(dataSource.materializeCalls, 0);

      createdControllers.single.completePlayback();
      await tester.pump();
      expect(find.byTooltip('重新播放'), findsOneWidget);
      await tester.tap(find.byTooltip('重新播放'));
      await tester.pump();
      expect(createdControllers.single.seekPositions, [Duration.zero]);
      expect(createdControllers.single.playCalls, 2);

      await tester.drag(find.byType(PhotoViewGallery), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('在线播放'), findsOneWidget);
      await tester.drag(find.byType(PhotoViewGallery), const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(createdControllers, hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(createdControllers.single.disposed, isTrue);
    },
  );

  testWidgets('Guest without Range support is directed to save to the album', (
    tester,
  ) async {
    final dataSource = _FakeGuestDataSource(
      supportsStreaming: false,
      files: [
        _record(
          id: 'video-1',
          name: 'clip.mp4',
          kind: 'video',
          mimeType: 'video/mp4',
          previewStatus: PreviewStatus.ready,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: linkNestLightTheme,
        localizationsDelegates: linkNestLocalizations,
        supportedLocales: const [Locale('zh'), Locale('en')],
        locale: const Locale('zh'),
        builder: (_, child) => LinkNestTheme(child: child!),
        home: SpaceGalleryScreen(
          dataSource: dataSource,
          native: LinkNestNative(),
          closeDataSourceOnDispose: false,
          guestMode: true,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('video-1')));
    await tester.pumpAndSettle();

    expect(find.text('在线播放'), findsNothing);
    expect(find.text('下载后播放'), findsNothing);
    expect(find.text('当前 Host 不支持在线播放，请先保存到相册'), findsOneWidget);
    expect(find.text('保存到相册请使用右上角按钮'), findsOneWidget);
    expect(dataSource.materializeCalls, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  testWidgets(
    'Forui gallery filters, grid size and live title preserve their behavior',
    (tester) async {
      final dataSource = _FakeGuestDataSource(
        files: [
          _record(id: 'old', uploadedAt: DateTime(2026, 9, 1)),
          _record(id: 'new', uploadedAt: DateTime(2026, 9, 2)),
        ],
      );
      await tester.pumpWidget(
        _galleryApp(
          SpaceGalleryScreen(
            dataSource: dataSource,
            native: LinkNestNative(),
            guestMode: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('new'))).dx,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('old'))).dx),
      );
      await tester.tap(find.byKey(const ValueKey('gallery-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最旧优先').last);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('关闭画廊选项'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('old'))).dx,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('new'))).dx),
      );
      await tester.tap(find.byKey(const ValueKey('gallery-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('大'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('关闭画廊选项'));
      await tester.pumpAndSettle();
      expect(
        (tester.widget<SliverGrid>(find.byType(SliverGrid).first).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2,
      );
      await tester.tap(find.byKey(const ValueKey('gallery-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上传者').last);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('关闭画廊选项'));
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const ValueKey('legacy:快乐海豚'))) +
            const Offset(24, 24),
      );
      await tester.pumpAndSettle();
      expect(find.text('返回'), findsOneWidget);
      dataSource.spaceName.value = '修改后的旅行名称';
      await tester.pump();
      expect(find.text('修改后的旅行名称'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'Forui multi-select saves only selected files and clears after success',
    (tester) async {
      final dataSource = _FakeGuestDataSource(
        allowMaterialize: true,
        files: [
          _record(id: 'one'),
          _record(id: 'two'),
        ],
      );
      final saved = <String>[];
      const channel = MethodChannel('linknest/native');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'saveToAlbum') {
          saved.add(call.arguments['path'] as String);
          return true;
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        _galleryApp(
          SpaceGalleryScreen(
            dataSource: dataSource,
            native: LinkNestNative(),
            guestMode: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('two')));
      await tester.pump();
      expect(find.text('已选 1 个'), findsOneWidget);
      expect(find.byType(PhotoViewGallery), findsNothing);
      await tester.tap(find.text('保存到本机'));
      await tester.pumpAndSettle();
      expect(saved, ['test/two.jpg']);
      expect(find.text('保存到本机'), findsNothing);
      expect(dataSource.materializeCalls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'narrow gallery keeps reconnect and retry reachable with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dataSource = _FakeGuestDataSource(
        interruptedUpload: true,
        files: [_record(id: 'one')],
      );
      dataSource.connectionState.value = const SpaceConnectionState(
        status: SpaceConnectionStatus.disconnected,
        message: '连接已中断，请重新连接热点后重试。',
      );
      await tester.pumpWidget(
        _galleryApp(
          SpaceGalleryScreen(
            dataSource: dataSource,
            native: LinkNestNative(),
            guestMode: true,
          ),
          scale: 1.8,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(find.byKey(const PageStorageKey('gallery-files')))
            .height,
        greaterThan(100),
      );
      await tester.ensureVisible(find.text('重新连接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新连接'));
      await tester.pumpAndSettle();
      expect(dataSource.reconnectCalls, 1);
      expect(dataSource.retryCalls, 1);
      dataSource.pendingUploadNames.value = const ['another.jpg'];
      await tester.pump();
      await tester.ensureVisible(find.text('重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(dataSource.retryCalls, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'Forui exit dialog cancels safely and disposes connection only after confirmation',
    (tester) async {
      final dataSource = _FakeGuestDataSource();
      await tester.pumpWidget(
        _galleryApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SpaceGalleryScreen(
                      dataSource: dataSource,
                      native: LinkNestNative(),
                      guestMode: true,
                    ),
                  ),
                ),
                child: const Text('测试入口'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('测试入口'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('guest-exit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(dataSource.closeCalls, 0);
      await tester.tap(find.byKey(const ValueKey('guest-exit')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(FDialog), matching: find.text('退出空间')),
      );
      await tester.pumpAndSettle();
      expect(dataSource.closeCalls, 1);
      expect(find.text('测试入口'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

FileRecord _record({
  required String id,
  String name = 'photo.jpg',
  String kind = 'image',
  String mimeType = 'image/jpeg',
  String previewStatus = PreviewStatus.ready,
  String uploaderId = '',
  DateTime? uploadedAt,
}) => FileRecord(
  id: id,
  name: name,
  size: 4,
  kind: kind,
  mimeType: mimeType,
  previewStatus: previewStatus,
  uploader: '快乐海豚',
  uploaderId: uploaderId,
  sha256: 'hash-$id',
  uploadedAt: uploadedAt ?? DateTime.fromMillisecondsSinceEpoch(1720000000000),
);

class _FakeGuestDataSource
    implements
        SpaceDataSource,
        GuestLifecycleDataSource,
        NetworkVideoDataSource,
        UploaderIdentityDataSource {
  _FakeGuestDataSource({
    this.uploaderId = '',
    String name = '周末旅行',
    String participant = '快乐海豚',
    bool interruptedUpload = false,
    this.supportsStreaming = true,
    this.allowMaterialize = false,
    List<FileRecord> files = const [],
  }) : pendingUploadNames = ValueNotifier(
         interruptedUpload ? const ['photo.jpg'] : const [],
       ),
       _interruptedUpload = interruptedUpload,
       files = List.of(files),
       spaceName = ValueNotifier(name),
       participantName = participant;

  @override
  final ValueNotifier<String> spaceName;

  @override
  final ValueNotifier<SpaceConnectionState> connectionState = ValueNotifier(
    SpaceConnectionState.connected,
  );

  @override
  final ValueNotifier<List<String>> pendingUploadNames;

  @override
  SpaceDataSourceCapabilities get capabilities =>
      SpaceDataSourceCapabilities.full;

  @override
  final String participantName;
  @override
  final String uploaderId;
  int listCalls = 0;
  int reconnectCalls = 0;
  int retryCalls = 0;
  int thumbnailCalls = 0;
  int materializeCalls = 0;
  final bool supportsStreaming;
  final bool allowMaterialize;
  int closeCalls = 0;
  bool _interruptedUpload;
  List<FileRecord> files;

  @override
  Future<List<FileRecord>> listFiles() async {
    listCalls++;
    return List.of(files);
  }

  @override
  Future<void> reconnect() async {
    reconnectCalls++;
  }

  @override
  bool consumeBackgroundInterruptedUpload() {
    final value = _interruptedUpload;
    _interruptedUpload = false;
    return value;
  }

  @override
  Future<AddFilesResult> retryPendingUploads({
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) async {
    retryCalls++;
    pendingUploadNames.value = const [];
    return const AddFilesResult(added: 1, skipped: 0);
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  Future<Uint8List> thumbnail(String id) async {
    thumbnailCalls++;
    return _testImageBytes;
  }

  @override
  Future<Uint8List> preview(String id) async => _testImageBytes;

  @override
  Future<LocalOriginal> materializeOriginal(
    FileRecord record, {
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) async {
    materializeCalls++;
    if (allowMaterialize) {
      return LocalOriginal(
        'test/${record.id}.${record.kind == 'video' ? 'mp4' : 'jpg'}',
      );
    }
    throw UnimplementedError('test does not materialize media');
  }

  @override
  NetworkVideoPlaybackSource? videoPlaybackSource(FileRecord record) =>
      !supportsStreaming
      ? null
      : NetworkVideoPlaybackSource(
          uri: Uri.parse(
            'http://192.168.43.1:8080/api/files/${record.id}/download',
          ),
          headers: const {'Authorization': 'Bearer test'},
        );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVideoPlayerController extends VideoPlayerController {
  _FakeVideoPlayerController()
    : super.networkUrl(Uri.parse('http://192.168.43.1/video.mp4'));

  int playCalls = 0;
  bool disposed = false;
  final List<Duration> seekPositions = [];

  @override
  Future<void> initialize() async {
    value = const VideoPlayerValue(
      duration: Duration(seconds: 10),
      size: Size(1920, 1080),
      isInitialized: true,
    );
  }

  @override
  Future<void> play() async {
    playCalls++;
    value = value.copyWith(isPlaying: true, isCompleted: false);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> seekTo(Duration position) async {
    seekPositions.add(position);
    value = value.copyWith(position: position, isCompleted: false);
  }

  void completePlayback() {
    value = value.copyWith(
      position: value.duration,
      isPlaying: false,
      isCompleted: true,
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

Widget _galleryApp(Widget home, {double scale = 1}) => MaterialApp(
  theme: linkNestLightTheme,
  locale: const Locale('zh'),
  supportedLocales: const [Locale('zh'), Locale('en')],
  localizationsDelegates: linkNestLocalizations,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: LinkNestTheme(child: child!),
  ),
  home: home,
);
