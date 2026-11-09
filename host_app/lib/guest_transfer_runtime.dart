import 'native.dart';
import 'space_data_source.dart';

abstract interface class GuestTransferRuntime {
  Stream<void> get backgroundTimeExpired;

  Future<void> start({
    required String direction,
    required String fileName,
    required int totalBytes,
  });

  Future<void> update(
    SpaceTransferProgress progress, {
    required String direction,
  });

  Future<void> stop();
}

class NativeGuestTransferRuntime implements GuestTransferRuntime {
  NativeGuestTransferRuntime(this._native);

  final LinkNestNative _native;

  @override
  Stream<void> get backgroundTimeExpired => _native.guestBackgroundTimeExpired;

  @override
  Future<void> start({
    required String direction,
    required String fileName,
    required int totalBytes,
  }) async {
    await _native.startGuestTransferService(
      direction: direction,
      fileName: fileName,
      totalBytes: totalBytes,
    );
  }

  @override
  Future<void> update(
    SpaceTransferProgress progress, {
    required String direction,
  }) => _native.updateGuestTransferService(
    direction: direction,
    fileName: progress.fileName,
    completedBytes: progress.completedBytes,
    totalBytes: progress.totalBytes,
  );

  @override
  Future<void> stop() => _native.stopGuestTransferService();
}
