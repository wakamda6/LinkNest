import 'media_format.dart';

class UploadFailure implements Exception {
  const UploadFailure(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  @override
  String toString() => message;
}

class UploadPolicy {
  const UploadPolicy({
    this.maxFileBytes = 10 * 1024 * 1024 * 1024,
    this.maxRequestBytes = 10 * 1024 * 1024 * 1024,
    this.reserveBytes = 512 * 1024 * 1024,
    this.maxFilesPerRequest = 20,
    this.maxUploaderBytes = 256,
    this.maxFilenameBytes = 255,
    this.maxConcurrentUploads = 4,
  });

  final int maxFileBytes;
  final int maxRequestBytes;
  final int reserveBytes;
  final int maxFilesPerRequest;
  final int maxUploaderBytes;
  final int maxFilenameBytes;
  final int maxConcurrentUploads;

  void checkMediaName(String name) {
    if (!MediaFormats.ofName(name).isAcceptedMedia) {
      throw const UploadFailure(
        415,
        'UNSUPPORTED_MEDIA_TYPE',
        'LinkNest 只接收已识别的图片和视频',
      );
    }
  }

  void checkSize(int bytes) {
    if (bytes > maxFileBytes) {
      throw const UploadFailure(413, 'FILE_TOO_LARGE', '文件超过单文件大小限制');
    }
  }

  void checkRequestSize(int bytes) {
    if (bytes > maxRequestBytes) {
      throw const UploadFailure(413, 'REQUEST_TOO_LARGE', '单次请求超过大小限制');
    }
  }

  void checkFileCount(int count) {
    if (count > maxFilesPerRequest) {
      throw const UploadFailure(413, 'TOO_MANY_FILES', '单次请求文件数量过多');
    }
  }

  void checkAvailable(int availableBytes, {int incomingBytes = 0}) {
    if (availableBytes >= 0 && availableBytes - incomingBytes < reserveBytes) {
      throw const UploadFailure(507, 'INSUFFICIENT_STORAGE', '设备剩余存储空间不足');
    }
  }
}
