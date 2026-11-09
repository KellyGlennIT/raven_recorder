import 'package:flutter_test/flutter_test.dart';
import 'package:raven/services/app_lock_service.dart';

void main() {
  test('accepts numeric PINs from four through twelve digits', () {
    expect(AppLockService.isValidPin('1234'), isTrue);
    expect(AppLockService.isValidPin('123456789012'), isTrue);
    expect(AppLockService.isValidPin('123'), isFalse);
    expect(AppLockService.isValidPin('1234567890123'), isFalse);
    expect(AppLockService.isValidPin('12a4'), isFalse);
  });
}
