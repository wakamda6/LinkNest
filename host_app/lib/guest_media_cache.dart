import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

typedef GuestFreeDiskBytesProvider = Future<int> Function();

class GuestMediaCacheException implements Exception {
  const GuestMediaCacheException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GuestMediaCacheKey {
  const GuestMediaCacheKey({
    required this.spaceId,
    required this.fileId,
    required this.role,
    required this.digest,
    this.extension = '',
  });

  final String spaceId;
  final String fileId;
  final String role;
  final String digest;
  final String extension;

  String get id => sha256
      .convert(utf8.encode('$spaceId\u0000$fileId\u0000$role\u0000$digest'))
      .toString();

  String get safeExtension {
    final value = extension.startsWith('.')
        ? extension.substring(1)
        : extension;
    return RegExp(r'^[A-Za-z0-9]{1,10}$').hasMatch(value)
        ? '.${value.toLowerCase()}'
        : '';
  }
}

class GuestCachedFiles {
  GuestCachedFiles._(this.files, this._release);

  final List<File> files;
  final Future<void> Function() _release;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _release();
  }
}

class GuestMediaCache {
  GuestMediaCache._({
    required Directory root,
    required this.maximumBytes,
    required this.reserveFreeBytes,
    required this._freeDiskBytesProvider,
  }) : _root = root,
       _indexFile = File('${root.path}${Platform.pathSeparator}index.json');

  static const int defaultMaximumBytes = 4 * 1024 * 1024 * 1024;
  static const int defaultReserveFreeBytes = 1024 * 1024 * 1024;
  static const int cacheDirectoryVersion = 1;
  static const int indexVersion = 3;

  final Directory _root;
  final File _indexFile;
  final int maximumBytes;
  final int reserveFreeBytes;
  final GuestFreeDiskBytesProvider _freeDiskBytesProvider;
  final Map<String, _GuestCacheEntry> _entries = {};
  final Map<String, int> _leases = {};
  final Map<String, Future<Uint8List>> _byteLoads = {};
  Future<void> _tail = Future.value();
  bool _closed = false;

  Directory get root => _root;

  static Future<GuestMediaCache> open({
    Future<Directory> Function()? rootDirectoryProvider,
    GuestFreeDiskBytesProvider? freeDiskBytesProvider,
    int maximumBytes = defaultMaximumBytes,
    int reserveFreeBytes = defaultReserveFreeBytes,
  }) async {
    final base = await (rootDirectoryProvider ?? getTemporaryDirectory)();
    final root = Directory(
      '${base.path}${Platform.pathSeparator}linknest-guest-media-cache'
      '${Platform.pathSeparator}v$cacheDirectoryVersion',
    );
    final cache = GuestMediaCache._(
      root: root,
      maximumBytes: maximumBytes,
      reserveFreeBytes: reserveFreeBytes,
      freeDiskBytesProvider: freeDiskBytesProvider ?? () async => -1,
    );
    await cache._initialize();
    return cache;
  }

  static Future<void> removeSpaceFromDefaultCache(String spaceId) async {
    final cache = await GuestMediaCache.open();
    try {
      await cache.deleteSpace(spaceId);
    } finally {
      await cache.close();
    }
  }

  Future<Uint8List?> readBytes(GuestMediaCacheKey key) => _locked(() async {
    _ensureOpen();
    final entry = _entries[key.id];
    if (entry == null || !entry.matches(key)) return null;
    final file = _fileFor(entry);
    if (!await _isValidFile(file, entry.size)) {
      await _removeEntry(entry);
      await _persist();
      return null;
    }
    final bytes = await file.readAsBytes();
    entry.lastAccessedAt = DateTime.now().toUtc();
    return bytes;
  });

  Future<Uint8List> getOrPutBytes(
    GuestMediaCacheKey key,
    Future<Uint8List> Function() loader,
  ) async {
    final cached = await readBytes(key);
    if (cached != null) return cached;
    final active = _byteLoads[key.id];
    if (active != null) return active;
    late final Future<Uint8List> request;
    request =
        (() async {
          final secondCheck = await readBytes(key);
          if (secondCheck != null) return secondCheck;
          final bytes = await loader();
          await putBytes(key, bytes);
          return bytes;
        })().whenComplete(() {
          if (identical(_byteLoads[key.id], request)) _byteLoads.remove(key.id);
        });
    _byteLoads[key.id] = request;
    return request;
  }

  Future<void> putBytes(GuestMediaCacheKey key, Uint8List bytes) =>
      _locked(() async {
        _ensureOpen();
        if (bytes.isEmpty || bytes.length > maximumBytes) return;
        await _ensureCapacity(bytes.length, replacing: {key.id});
        final destination = _destination(key);
        final partial = File('${destination.path}.part');
        try {
          if (await partial.exists()) await partial.delete();
          await partial.writeAsBytes(bytes, flush: true);
          if (await destination.exists()) await destination.delete();
          await partial.rename(destination.path);
          final previous = _entries[key.id];
          if (previous != null &&
              previous.relativePath != _relative(destination)) {
            await _deleteQuietly(_fileFor(previous));
          }
          _entries[key.id] = _GuestCacheEntry.fromKey(
            key,
            relativePath: _relative(destination),
            size: bytes.length,
          );
          await _persist();
        } finally {
          await _deleteQuietly(partial);
        }
      });

  Future<GuestCachedFiles?> acquireFiles(List<GuestMediaCacheKey> keys) =>
      _locked(() async {
        _ensureOpen();
        final entries = <_GuestCacheEntry>[];
        final files = <File>[];
        for (final key in keys) {
          final entry = _entries[key.id];
          if (entry == null || !entry.matches(key)) return null;
          final file = _fileFor(entry);
          if (!await _isValidFile(file, entry.size)) {
            await _removeEntry(entry);
            await _persist();
            return null;
          }
          entries.add(entry);
          files.add(file);
        }
        final now = DateTime.now().toUtc();
        for (final entry in entries) {
          entry.lastAccessedAt = now;
          _leases[entry.id] = (_leases[entry.id] ?? 0) + 1;
        }
        return GuestCachedFiles._(files, () => _release(entries));
      });

  Future<void> storeFiles(Map<GuestMediaCacheKey, File> sources) =>
      _locked(() async {
        _ensureOpen();
        if (sources.isEmpty) return;
        final sizes = <GuestMediaCacheKey, int>{};
        var requiredBytes = 0;
        for (final item in sources.entries) {
          if (!await item.value.exists()) {
            throw const GuestMediaCacheException('待缓存文件不存在。');
          }
          final size = await item.value.length();
          if (size <= 0 || size > maximumBytes) {
            throw const GuestMediaCacheException('待缓存文件大小无效。');
          }
          sizes[item.key] = size;
          requiredBytes += size;
        }
        if (requiredBytes > maximumBytes) {
          throw const GuestMediaCacheException('媒体大于缓存总预算。');
        }
        await _ensureCapacity(
          requiredBytes,
          replacing: sources.keys.map((e) => e.id).toSet(),
        );

        final staged = <GuestMediaCacheKey, File>{};
        try {
          for (final item in sources.entries) {
            final destination = _destination(item.key);
            final partial = File('${destination.path}.part');
            await _deleteQuietly(partial);
            await item.value.copy(partial.path);
            final handle = await partial.open(mode: FileMode.append);
            await handle.flush();
            await handle.close();
            staged[item.key] = partial;
          }
          for (final item in staged.entries) {
            final destination = _destination(item.key);
            if (await destination.exists()) await destination.delete();
            await item.value.rename(destination.path);
          }
          for (final item in sources.entries) {
            final destination = _destination(item.key);
            final previous = _entries[item.key.id];
            if (previous != null &&
                previous.relativePath != _relative(destination)) {
              await _deleteQuietly(_fileFor(previous));
            }
            _entries[item.key.id] = _GuestCacheEntry.fromKey(
              item.key,
              relativePath: _relative(destination),
              size: sizes[item.key]!,
            );
          }
          await _persist();
        } finally {
          for (final file in staged.values) {
            await _deleteQuietly(file);
          }
        }
      });

  Future<void> remove(GuestMediaCacheKey key) => _locked(() async {
    _ensureOpen();
    final entry = _entries[key.id];
    if (entry == null) return;
    await _removeEntry(entry);
    await _persist();
  });

  Future<void> deleteFile(String spaceId, String fileId) => _locked(() async {
    _ensureOpen();
    final stale = _entries.values
        .where((entry) => entry.spaceId == spaceId && entry.fileId == fileId)
        .toList();
    for (final entry in stale) {
      await _removeEntry(entry);
    }
    if (stale.isNotEmpty) await _persist();
  });

  Future<void> deleteSpace(String spaceId) => _locked(() async {
    _ensureOpen();
    final stale = _entries.values
        .where((entry) => entry.spaceId == spaceId)
        .toList();
    for (final entry in stale) {
      await _removeEntry(entry);
    }
    if (stale.isNotEmpty) await _persist();
  });

  Future<void> reconcileSpace(
    String spaceId,
    Map<String, Set<String>> validDigests,
  ) => _locked(() async {
    _ensureOpen();
    final stale = _entries.values.where((entry) {
      if (entry.spaceId != spaceId) return false;
      final digests = validDigests[entry.fileId];
      return digests == null || !digests.contains(entry.digest);
    }).toList();
    for (final entry in stale) {
      await _removeEntry(entry);
    }
    if (stale.isNotEmpty) await _persist();
  });

  Future<void> close() async {
    await _locked(() async {
      if (_closed) return;
      await _persist();
      _closed = true;
    });
  }

  Future<void> _initialize() async {
    await _root.create(recursive: true);
    await for (final entity in _root.list()) {
      if (entity is File && entity.path.endsWith('.part')) {
        await _deleteQuietly(entity);
      }
    }
    if (!await _indexFile.exists()) return;
    try {
      final decoded = jsonDecode(await _indexFile.readAsString());
      if (decoded is! Map ||
          (decoded['version'] != 1 &&
              decoded['version'] != 2 &&
              decoded['version'] != indexVersion) ||
          decoded['entries'] is! List) {
        throw const FormatException('缓存索引版本无效');
      }
      for (final value in decoded['entries'] as List) {
        if (value is! Map) continue;
        final entry = _GuestCacheEntry.fromJson(value);
        if (entry == null) continue;
        final file = _fileFor(entry);
        if (entry.role.startsWith('videoBlock:')) {
          await _deleteQuietly(file);
          continue;
        }
        if (await _isValidFile(file, entry.size)) {
          _entries[entry.id] = entry;
        } else {
          await _deleteQuietly(file);
        }
      }
      await _deleteOrphans();
      await _persist();
    } catch (_) {
      await _clearFiles();
      _entries.clear();
      await _persist();
    }
  }

  Future<void> _ensureCapacity(
    int incomingBytes, {
    Set<String> replacing = const {},
  }) async {
    var currentBytes = _entries.values
        .where((entry) => !replacing.contains(entry.id))
        .fold<int>(0, (sum, entry) => sum + entry.size);
    var freeBytes = await _freeDiskBytesProvider();
    final candidates =
        <_GuestEvictionCandidate>[
          for (final entry in _entries.values)
            if (!replacing.contains(entry.id) && (_leases[entry.id] ?? 0) == 0)
              _GuestEvictionCandidate(
                size: entry.size,
                lastAccessedAt: entry.lastAccessedAt,
                remove: () => _removeEntry(entry),
              ),
        ]..sort(
          (left, right) => left.lastAccessedAt.compareTo(right.lastAccessedAt),
        );
    var index = 0;
    while (currentBytes + incomingBytes > maximumBytes ||
        (freeBytes >= 0 && freeBytes < reserveFreeBytes + incomingBytes)) {
      if (index >= candidates.length) {
        throw const GuestMediaCacheException('缓存空间不足。');
      }
      final candidate = candidates[index++];
      currentBytes -= candidate.size;
      if (freeBytes >= 0) freeBytes += candidate.size;
      await candidate.remove();
    }
  }

  Future<void> _release(List<_GuestCacheEntry> entries) => _locked(() async {
    for (final entry in entries) {
      final count = _leases[entry.id] ?? 0;
      if (count <= 1) {
        _leases.remove(entry.id);
      } else {
        _leases[entry.id] = count - 1;
      }
    }
  });

  Future<void> _removeEntry(_GuestCacheEntry entry) async {
    _entries.remove(entry.id);
    _leases.remove(entry.id);
    await _deleteQuietly(_fileFor(entry));
  }

  Future<void> _deleteOrphans() async {
    final retained =
        _entries.values.map((entry) => _fileFor(entry).path).toSet()
          ..add(_indexFile.path);
    await for (final entity in _root.list()) {
      if (entity is File && !retained.contains(entity.path)) {
        await _deleteQuietly(entity);
      }
    }
  }

  Future<void> _clearFiles() async {
    await for (final entity in _root.list()) {
      if (entity is File) await _deleteQuietly(entity);
    }
  }

  File _destination(GuestMediaCacheKey key) => File(
    '${_root.path}${Platform.pathSeparator}${key.id}${key.safeExtension}',
  );

  File _fileFor(_GuestCacheEntry entry) =>
      File('${_root.path}${Platform.pathSeparator}${entry.relativePath}');

  String _relative(File file) => file.uri.pathSegments.last;

  Future<void> _persist() async {
    if (!await _root.exists()) return;
    final partial = File('${_indexFile.path}.part');
    final payload = jsonEncode({
      'version': indexVersion,
      'entries': _entries.values.map((entry) => entry.toJson()).toList(),
    });
    await partial.writeAsString(payload, flush: true);
    if (await _indexFile.exists()) await _indexFile.delete();
    await partial.rename(_indexFile.path);
  }

  Future<T> _locked<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _ensureOpen() {
    if (_closed) throw const GuestMediaCacheException('媒体缓存已关闭。');
  }

  static Future<bool> _isValidFile(File file, int size) async =>
      await file.exists() && await file.length() == size;

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 缓存清理失败时由后续启动维护再次收敛。
    }
  }
}

class _GuestCacheEntry {
  _GuestCacheEntry({
    required this.id,
    required this.spaceId,
    required this.fileId,
    required this.role,
    required this.digest,
    required this.relativePath,
    required this.size,
    required this.lastAccessedAt,
  });

  factory _GuestCacheEntry.fromKey(
    GuestMediaCacheKey key, {
    required String relativePath,
    required int size,
  }) => _GuestCacheEntry(
    id: key.id,
    spaceId: key.spaceId,
    fileId: key.fileId,
    role: key.role,
    digest: key.digest,
    relativePath: relativePath,
    size: size,
    lastAccessedAt: DateTime.now().toUtc(),
  );

  static _GuestCacheEntry? fromJson(Map<dynamic, dynamic> json) {
    final id = json['id'];
    final spaceId = json['spaceId'];
    final fileId = json['fileId'];
    final role = json['role'];
    final digest = json['digest'];
    final relativePath = json['relativePath'];
    final size = json['size'];
    final lastAccessedAt = json['lastAccessedAt'];
    if (id is! String ||
        spaceId is! String ||
        fileId is! String ||
        role is! String ||
        digest is! String ||
        relativePath is! String ||
        size is! int ||
        size <= 0 ||
        lastAccessedAt is! int ||
        !RegExp(r'^[a-f0-9]{64}(\.[a-z0-9]{1,10})?$').hasMatch(relativePath)) {
      return null;
    }
    return _GuestCacheEntry(
      id: id,
      spaceId: spaceId,
      fileId: fileId,
      role: role,
      digest: digest,
      relativePath: relativePath,
      size: size,
      lastAccessedAt: DateTime.fromMillisecondsSinceEpoch(
        lastAccessedAt,
        isUtc: true,
      ),
    );
  }

  final String id;
  final String spaceId;
  final String fileId;
  final String role;
  final String digest;
  final String relativePath;
  final int size;
  DateTime lastAccessedAt;

  bool matches(GuestMediaCacheKey key) =>
      id == key.id &&
      spaceId == key.spaceId &&
      fileId == key.fileId &&
      role == key.role &&
      digest == key.digest;

  Map<String, Object> toJson() => {
    'id': id,
    'spaceId': spaceId,
    'fileId': fileId,
    'role': role,
    'digest': digest,
    'relativePath': relativePath,
    'size': size,
    'lastAccessedAt': lastAccessedAt.millisecondsSinceEpoch,
  };
}

class _GuestEvictionCandidate {
  const _GuestEvictionCandidate({
    required this.size,
    required this.lastAccessedAt,
    required this.remove,
  });

  final int size;
  final DateTime lastAccessedAt;
  final Future<void> Function() remove;
}
