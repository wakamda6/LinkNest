import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'file_record.dart';

/// 单 isolate 内的异步互斥锁。锁在调用点同步排队，不会遗漏同时到达的请求。
class AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> protect<T>(Future<T> Function() action) {
    final previous = _tail;
    final released = Completer<void>();
    _tail = released.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        released.complete();
      }
    });
  }
}

/// 单 isolate 内的有界异步执行器，避免同时启动过多原生解码任务。
class AsyncLimiter {
  AsyncLimiter(this.maxConcurrent) : assert(maxConcurrent > 0);

  final int maxConcurrent;
  final Queue<Completer<void>> _waiters = Queue();
  int _active = 0;

  Future<T> protect<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _active--;
    }
  }
}

/// `index.json` 的恢复和原子落盘。
class IndexStore {
  IndexStore(this.root);

  final Directory root;

  File get _index => File('${root.path}/index.json');
  File get _temporary => File('${root.path}/index.json.tmp');
  File get _backup => File('${root.path}/index.json.bak');

  Future<List<Map<dynamic, dynamic>>> load() async {
    if (!await _index.exists() && await _backup.exists()) {
      await _backup.rename(_index.path);
    } else if (await _index.exists() && await _backup.exists()) {
      await _backup.delete();
    }
    if (await _temporary.exists()) {
      await _temporary.delete();
    }
    if (!await _index.exists()) return [];
    final decoded = jsonDecode(await _index.readAsString());
    if (decoded is! List) {
      throw const FormatException('index.json must contain a list');
    }
    return decoded.whereType<Map>().toList();
  }

  Future<void> save(List<FileRecord> records) async {
    await _temporary.writeAsString(
      jsonEncode(records.map((e) => e.toJson()).toList()),
      flush: true,
    );

    if (!Platform.isWindows || !await _index.exists()) {
      await _temporary.rename(_index.path);
      return;
    }

    // Windows 不允许 rename 覆盖现有目标；备份让启动恢复仍有完整索引可用。
    if (await _backup.exists()) await _backup.delete();
    await _index.rename(_backup.path);
    try {
      await _temporary.rename(_index.path);
      try {
        await _backup.delete();
      } catch (_) {
        // 新索引已经完整替换；残留备份会在下次启动清理。
      }
    } catch (_) {
      if (!await _index.exists() && await _backup.exists()) {
        await _backup.rename(_index.path);
      }
      rethrow;
    }
  }
}
