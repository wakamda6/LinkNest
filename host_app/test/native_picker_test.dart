import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/native.dart';
import 'package:linknest/space_data_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'REQ-0008 album channel preserves Live Photo paired resources',
    () async {
      const channel = MethodChannel('linknest/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pickFromAlbum');
        return [
          {
            'path': '/cache/live.heic',
            'name': 'live.heic',
            'pairedVideoPath': '/cache/live.mov',
            'pairedVideoName': 'live.mov',
          },
          {'path': '/cache/still.heic', 'name': 'still.heic'},
        ];
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final selected = (await LinkNestNative().pickFromAlbum())
          .map(PickedMedia.fromMap)
          .toList();

      expect(selected, hasLength(2));
      expect(selected.first.isLivePhoto, isTrue);
      expect(selected.first.pairedVideoPath, '/cache/live.mov');
      expect(selected.first.pairedVideoName, 'live.mov');
      expect(selected.last.isLivePhoto, isFalse);
    },
  );
}
