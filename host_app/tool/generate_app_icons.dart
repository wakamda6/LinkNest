import 'dart:io';

// flutter_launcher_icons 0.14.4 会误改名称之外的 ASSETCATALOG 设置。
// 本项目已使用默认 AppIcon 目录，仅生成资源，保留原有 Xcode 设置。
Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent;
  final project = File('${root.path}/ios/Runner.xcodeproj/project.pbxproj');
  final setting = RegExp(r'ASSETCATALOG\w*\s*=\s*[^;]+;');
  final original = setting.allMatches(project.readAsStringSync()).map((match) {
    return match.group(0)!;
  }).toList();
  if (original.isEmpty ||
      original.any(
        (line) =>
            line.startsWith('ASSETCATALOG_COMPILER_APPICON_NAME') &&
            !line.endsWith('= AppIcon;'),
      )) {
    throw StateError('图标生成已停止：请确认 Xcode 使用默认 AppIcon 目录。');
  }
  try {
    stdout.writeln('正在生成 Android 与 iOS 图标……');
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'flutter_launcher_icons'],
      workingDirectory: root.path,
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await process.exitCode;
  } finally {
    final generated = project.readAsStringSync();
    final current = setting.allMatches(generated).toList();
    if (current.length != original.length ||
        List.generate(original.length, (index) => index).any(
          (index) =>
              current[index].group(0)!.split('=').first.trim() !=
              original[index].split('=').first.trim(),
        )) {
      throw StateError('Xcode 配置结构已变化，请检查图标生成差异后再构建。');
    }
    var index = 0;
    final restored = generated.replaceAllMapped(
      setting,
      (_) => original[index++],
    );
    if (restored != generated) {
      project.writeAsStringSync(restored);
      stdout.writeln('已恢复图标工具误改的 Xcode 设置。');
    }
  }
}
