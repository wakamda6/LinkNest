enum MediaSupportLevel { full, basic, transferOnly, unsupported }

/// LinkNest v1 媒体格式的唯一映射表。
///
/// 服务端元数据、下载 Content-Type 和原生相册保存都使用这里生成的
/// `kind` / `mimeType`，避免各层独立猜测后产生不一致。
class MediaFormat {
  const MediaFormat({
    required this.kind,
    required this.mimeType,
    required this.previewSupported,
    required this.supportLevel,
  });

  final String kind;
  final String mimeType;
  final bool previewSupported;
  final MediaSupportLevel supportLevel;

  bool get isAcceptedMedia =>
      (kind == 'image' || kind == 'video') &&
      supportLevel != MediaSupportLevel.unsupported;

  bool get savesToAlbum =>
      supportLevel == MediaSupportLevel.full ||
      supportLevel == MediaSupportLevel.basic;

  bool get savesToFiles => supportLevel == MediaSupportLevel.transferOnly;
}

class MediaFormats {
  static const MediaFormat unknown = MediaFormat(
    kind: 'other',
    mimeType: 'application/octet-stream',
    previewSupported: false,
    supportLevel: MediaSupportLevel.unsupported,
  );

  static const Map<String, MediaFormat> _byExtension = {
    'jpg': MediaFormat(
      kind: 'image',
      mimeType: 'image/jpeg',
      previewSupported: true,
      supportLevel: MediaSupportLevel.full,
    ),
    'jpeg': MediaFormat(
      kind: 'image',
      mimeType: 'image/jpeg',
      previewSupported: true,
      supportLevel: MediaSupportLevel.full,
    ),
    'png': MediaFormat(
      kind: 'image',
      mimeType: 'image/png',
      previewSupported: true,
      supportLevel: MediaSupportLevel.full,
    ),
    'heic': MediaFormat(
      kind: 'image',
      mimeType: 'image/heic',
      previewSupported: true,
      supportLevel: MediaSupportLevel.full,
    ),
    'heif': MediaFormat(
      kind: 'image',
      mimeType: 'image/heif',
      previewSupported: true,
      supportLevel: MediaSupportLevel.full,
    ),
    'gif': MediaFormat(
      kind: 'image',
      mimeType: 'image/gif',
      previewSupported: true,
      supportLevel: MediaSupportLevel.basic,
    ),
    'webp': MediaFormat(
      kind: 'image',
      mimeType: 'image/webp',
      previewSupported: true,
      supportLevel: MediaSupportLevel.basic,
    ),
    'bmp': MediaFormat(
      kind: 'image',
      mimeType: 'image/bmp',
      previewSupported: false,
      supportLevel: MediaSupportLevel.transferOnly,
    ),
    'tif': MediaFormat(
      kind: 'image',
      mimeType: 'image/tiff',
      previewSupported: false,
      supportLevel: MediaSupportLevel.transferOnly,
    ),
    'tiff': MediaFormat(
      kind: 'image',
      mimeType: 'image/tiff',
      previewSupported: false,
      supportLevel: MediaSupportLevel.transferOnly,
    ),
    'mp4': MediaFormat(
      kind: 'video',
      mimeType: 'video/mp4',
      previewSupported: true,
      supportLevel: MediaSupportLevel.full,
    ),
    'm4v': MediaFormat(
      kind: 'video',
      mimeType: 'video/mp4',
      previewSupported: true,
      supportLevel: MediaSupportLevel.full,
    ),
    'mov': MediaFormat(
      kind: 'video',
      mimeType: 'video/quicktime',
      previewSupported: true,
      supportLevel: MediaSupportLevel.full,
    ),
    '3gp': MediaFormat(
      kind: 'video',
      mimeType: 'video/3gpp',
      previewSupported: true,
      supportLevel: MediaSupportLevel.basic,
    ),
    'mkv': MediaFormat(
      kind: 'video',
      mimeType: 'video/x-matroska',
      previewSupported: false,
      supportLevel: MediaSupportLevel.transferOnly,
    ),
    'webm': MediaFormat(
      kind: 'video',
      mimeType: 'video/webm',
      previewSupported: false,
      supportLevel: MediaSupportLevel.transferOnly,
    ),
    'avi': MediaFormat(
      kind: 'video',
      mimeType: 'video/x-msvideo',
      previewSupported: false,
      supportLevel: MediaSupportLevel.transferOnly,
    ),
    'mpeg': MediaFormat(
      kind: 'video',
      mimeType: 'video/mpeg',
      previewSupported: false,
      supportLevel: MediaSupportLevel.transferOnly,
    ),
    'mpg': MediaFormat(
      kind: 'video',
      mimeType: 'video/mpeg',
      previewSupported: false,
      supportLevel: MediaSupportLevel.transferOnly,
    ),
  };

  static MediaFormat ofName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return unknown;
    return _byExtension[name.substring(dot + 1).toLowerCase()] ?? unknown;
  }

  /// 只接受与文件扩展名分类一致、且在 v1 映射表中出现过的声明类型。
  /// 浏览器提交的任意 Content-Type 不会直接成为持久化元数据。
  static MediaFormat resolve(String name, {String? declaredMimeType}) {
    final byName = ofName(name);
    final declared = declaredMimeType?.split(';').first.trim().toLowerCase();
    if (declared == null || declared.isEmpty) return byName;
    if (byName == unknown) return unknown;
    final matches = _byExtension.values.where((f) => f.mimeType == declared);
    if (matches.isEmpty) return byName;
    if (matches.any((f) => f.kind == byName.kind)) {
      return MediaFormat(
        kind: byName.kind,
        mimeType: declared,
        previewSupported: byName.previewSupported,
        supportLevel: byName.supportLevel,
      );
    }
    return byName;
  }
}
