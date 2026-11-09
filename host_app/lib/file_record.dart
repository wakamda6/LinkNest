import 'media_format.dart';

class MediaResource {
  const MediaResource({
    required this.name,
    required this.size,
    required this.mimeType,
    required this.sha256,
  });

  factory MediaResource.fromJson(Map<dynamic, dynamic> json) => MediaResource(
    name: json['name']?.toString() ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    mimeType: json['mimeType']?.toString() ?? 'application/octet-stream',
    sha256: json['sha256']?.toString() ?? '',
  );

  final String name;
  final int size;
  final String mimeType;
  final String sha256;

  Map<String, dynamic> toJson() => {
    'name': name,
    'size': size,
    'mimeType': mimeType,
    'sha256': sha256,
  };
}

class PreviewStatus {
  static const unknown = 'unknown';
  static const ready = 'ready';
  static const unsupported = 'unsupported';
  static const failed = 'failed';

  static bool isValid(String value) =>
      value == unknown ||
      value == ready ||
      value == unsupported ||
      value == failed;
}

class PhotoLocationStatus {
  static const unknown = 'unknown';
  static const noGps = 'noGps';
  static const pending = 'pending';
  static const resolved = 'resolved';

  static bool isValid(String value) =>
      value == unknown ||
      value == noGps ||
      value == pending ||
      value == resolved;
}

/// 仅保存在 Host 内部的照片位置。不得加入公开 API 或普通日志。
class PhotoLocation {
  const PhotoLocation({
    required this.status,
    this.latitude,
    this.longitude,
    this.label,
  });

  factory PhotoLocation.fromJson(Map<dynamic, dynamic> json) {
    final status = json['status']?.toString() ?? PhotoLocationStatus.unknown;
    return PhotoLocation(
      status: PhotoLocationStatus.isValid(status)
          ? status
          : PhotoLocationStatus.unknown,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      label: json['label']?.toString(),
    );
  }

  final String status;
  final double? latitude;
  final double? longitude;
  final String? label;

  Map<String, dynamic> toJson() => {
    'status': status,
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
    if (label != null && label!.isNotEmpty) 'label': label,
  };
}

/// 空间内一个原文件及其可持久化元数据。
class FileRecord {
  const FileRecord({
    required this.id,
    required this.name,
    required this.size,
    required this.kind,
    required this.mimeType,
    required this.previewStatus,
    required this.uploader,
    required this.sha256,
    required this.uploadedAt,
    this.uploaderId = '',
    this.spaceId = '',
    this.sessionId = '',
    this.photoResource,
    this.pairedVideo,
    this.photoLocation,
  });

  factory FileRecord.fromJson(Map<dynamic, dynamic> json) {
    final name = json['name']?.toString() ?? '';
    final format = MediaFormats.ofName(name);
    final storedStatus = json['previewStatus']?.toString() ?? '';
    return FileRecord(
      id: json['id']?.toString() ?? '',
      name: name,
      size: (json['size'] as num?)?.toInt() ?? 0,
      kind: json['kind']?.toString() ?? format.kind,
      mimeType: json['mimeType']?.toString() ?? format.mimeType,
      previewStatus: PreviewStatus.isValid(storedStatus)
          ? storedStatus
          : (format.previewSupported
                ? PreviewStatus.unknown
                : PreviewStatus.unsupported),
      uploader: json['uploader']?.toString() ?? '',
      uploaderId: json['uploaderId']?.toString() ?? '',
      sha256: json['sha256']?.toString() ?? '',
      uploadedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['uploadedAt'] as num?)?.toInt() ?? 0,
      ),
      spaceId: json['spaceId']?.toString() ?? '',
      sessionId: json['sessionId']?.toString() ?? '',
      photoResource: _resource(json, 'photo'),
      pairedVideo: _resource(json, 'pairedVideo'),
      photoLocation: json['photoLocation'] is Map
          ? PhotoLocation.fromJson(json['photoLocation'] as Map)
          : null,
    );
  }

  final String id;
  final String name;
  final int size;
  final String kind;
  final String mimeType;
  final String previewStatus;
  final String uploader;
  final String uploaderId;
  final String sha256;
  final DateTime uploadedAt;
  final String spaceId;
  final String sessionId;
  final MediaResource? photoResource;
  final MediaResource? pairedVideo;
  final PhotoLocation? photoLocation;

  bool get isLivePhoto => photoResource != null && pairedVideo != null;

  MediaResource get primaryResource =>
      photoResource ??
      MediaResource(name: name, size: size, mimeType: mimeType, sha256: sha256);

  bool get hasThumb =>
      kind != 'other' &&
      previewStatus != PreviewStatus.unsupported &&
      previewStatus != PreviewStatus.failed;

  bool hasSameMediaContentAs(FileRecord other) =>
      id == other.id &&
      name == other.name &&
      kind == other.kind &&
      mimeType == other.mimeType &&
      sha256 == other.sha256 &&
      _sameResource(photoResource, other.photoResource) &&
      _sameResource(pairedVideo, other.pairedVideo);

  bool hasSamePreviewAs(FileRecord other) =>
      hasSameMediaContentAs(other) && previewStatus == other.previewStatus;

  bool hasSamePresentationAs(FileRecord other) =>
      hasSamePreviewAs(other) &&
      size == other.size &&
      uploader == other.uploader &&
      uploaderId == other.uploaderId &&
      uploadedAt == other.uploadedAt &&
      spaceId == other.spaceId &&
      sessionId == other.sessionId;

  FileRecord copyWith({
    String? previewStatus,
    String? spaceId,
    String? sessionId,
    PhotoLocation? photoLocation,
  }) => FileRecord(
    id: id,
    name: name,
    size: size,
    kind: kind,
    mimeType: mimeType,
    previewStatus: previewStatus ?? this.previewStatus,
    uploader: uploader,
    uploaderId: uploaderId,
    sha256: sha256,
    uploadedAt: uploadedAt,
    spaceId: spaceId ?? this.spaceId,
    sessionId: sessionId ?? this.sessionId,
    photoResource: photoResource,
    pairedVideo: pairedVideo,
    photoLocation: photoLocation ?? this.photoLocation,
  );

  /// Guest/Web 可见字段。Host 私有归属和后续地点元数据不得加入这里。
  Map<String, dynamic> toPublicJson() => {
    'id': id,
    'name': name,
    'size': size,
    'kind': kind,
    'mimeType': mimeType,
    'previewStatus': previewStatus,
    'uploader': uploader,
    if (uploaderId.isNotEmpty) 'uploaderId': uploaderId,
    'hasThumb': hasThumb,
    'sha256': sha256,
    'uploadedAt': uploadedAt.millisecondsSinceEpoch,
    if (isLivePhoto) 'mediaType': 'livePhoto',
    if (isLivePhoto)
      'resources': {
        'photo': photoResource!.toJson(),
        'pairedVideo': pairedVideo!.toJson(),
      },
  };

  /// Host 本地状态和事务使用的完整记录。
  Map<String, dynamic> toStorageJson() => {
    ...toPublicJson(),
    'spaceId': spaceId,
    'sessionId': sessionId,
    if (photoLocation != null) 'photoLocation': photoLocation!.toJson(),
  };

  /// 保留现有调用兼容性；公开响应必须使用公开序列化。
  Map<String, dynamic> toJson() => toPublicJson();

  static MediaResource? _resource(Map<dynamic, dynamic> json, String role) {
    final resources = json['resources'];
    if (resources is! Map || resources[role] is! Map) return null;
    return MediaResource.fromJson(resources[role] as Map);
  }

  static bool _sameResource(MediaResource? left, MediaResource? right) {
    if (identical(left, right)) return true;
    if (left == null || right == null) return false;
    return left.name == right.name &&
        left.size == right.size &&
        left.mimeType == right.mimeType &&
        left.sha256 == right.sha256;
  }
}
