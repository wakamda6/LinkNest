import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:linknest/app_identity.dart';

void main() {
  test(
    'REQ-1203 restores installation identity and isolates public IDs by space',
    () async {
      SharedPreferences.setMockInitialValues({});
      var prefs = await SharedPreferences.getInstance();
      await AppIdentity.initialize(prefs);
      final original = AppIdentity.id;
      expect(AppIdentity.validId.hasMatch(original), isTrue);
      SharedPreferences.setMockInitialValues({
        AppIdentity.preferenceKey: original,
      });
      prefs = await SharedPreferences.getInstance();
      await AppIdentity.initialize(prefs);
      expect(AppIdentity.id, original);
      expect(
        AppIdentity.forSpace('a', original),
        isNot(AppIdentity.forSpace('b', original)),
      );
      expect(AppIdentity.forSpace('a', ''), isEmpty);
    },
  );
}
