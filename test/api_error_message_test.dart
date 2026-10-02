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
    'evidence rejection explains public website and local/IP restrictions',
    () {
      expect(
        apiErrorMessage('INVALID_EVIDENCE_URL'),
        '공개 웹사이트의 http 또는 https 주소를 입력해주세요. 로컬·IP 주소나 공백·로그인 정보가 있는 URL은 사용할 수 없습니다.',
      );
    },
  );
  test(
    'unknown English errors fall back to Korean; Korean details survive',
    () {
      expect(apiErrorMessage('UNKNOWN', 'SQL details'), isNot(contains('SQL')));
      expect(apiErrorMessage('UNKNOWN', '입력 내용이 잘못되었습니다.'), '입력 내용이 잘못되었습니다.');
    },
  );
}
