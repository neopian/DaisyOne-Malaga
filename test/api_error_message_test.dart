import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';

void main() {
  for (final code in [
    'INSUFFICIENT_POINTS',
    'QUESTION_UNAVAILABLE',
    'REGION_MISMATCH',
    'CANNOT_CANCEL',
    'INVALID_CREDENTIALS',
    'UNAUTHENTICATED',
  ]) {
    test('$code has a useful Korean message', () {
      final message = apiErrorMessage(code, 'English server detail');
      expect(RegExp(r'[가-힣]').hasMatch(message), isTrue);
      expect(message, isNot(contains('English')));
      expect(message, isNot(apiErrorMessage('UNKNOWN')));
    });
  }
  test(
    'unknown English errors fall back to Korean; Korean details survive',
    () {
      expect(apiErrorMessage('UNKNOWN', 'SQL details'), isNot(contains('SQL')));
      expect(apiErrorMessage('UNKNOWN', '입력 내용이 잘못되었습니다.'), '입력 내용이 잘못되었습니다.');
    },
  );
}
