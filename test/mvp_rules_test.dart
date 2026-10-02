import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/core/services/mvp_rules.dart';

void main() {
  group('MvpRules', () {
    test('신규 질문은 보상 포인트가 잔액 이하여야 한다', () {
      expect(
        MvpRules.canCreateQuestion(pointBalance: 1000, rewardPoints: 100),
        isTrue,
      );
      expect(
        MvpRules.canCreateQuestion(pointBalance: 50, rewardPoints: 100),
        isFalse,
      );
      expect(
        MvpRules.canCreateQuestion(pointBalance: 1000, rewardPoints: 0),
        isFalse,
      );
    });

    test('질문 등록 시 보상 포인트가 보류된다', () {
      final move = MvpRules.holdReward(
        questionerBalance: 1000,
        rewardPoints: 250,
      );

      expect(move.questionerBalance, 750);
      expect(move.transactionAmount, -250);
      expect(move.transactionType, 'hold');
    });

    test('승인된 답변자만 open 질문을 수락할 수 있다', () {
      expect(
        MvpRules.canAcceptQuestion(
          questionStatus: 'open',
          helperApproved: true,
          questionOwnerId: 'questioner',
          currentUserId: 'helper',
        ),
        isTrue,
      );
      expect(
        MvpRules.canAcceptQuestion(
          questionStatus: 'assigned',
          helperApproved: true,
          questionOwnerId: 'questioner',
          currentUserId: 'helper',
        ),
        isFalse,
      );
      expect(
        MvpRules.canAcceptQuestion(
          questionStatus: 'open',
          helperApproved: false,
          questionOwnerId: 'questioner',
          currentUserId: 'helper',
        ),
        isFalse,
      );
    });

    test('승인된 답변자도 자기 질문을 수락할 수 없다', () {
      expect(
        MvpRules.canAcceptQuestion(
          questionStatus: 'open',
          helperApproved: true,
          questionOwnerId: 'same-user',
          currentUserId: 'same-user',
        ),
        isFalse,
      );
      expect(
        MvpRules.canAcceptQuestion(
          questionStatus: 'open',
          helperApproved: true,
          questionOwnerId: ' same-user ',
          currentUserId: 'same-user',
        ),
        isFalse,
      );
    });

    test('로그인 또는 질문 작성자 정보가 없으면 수락할 수 없다', () {
      for (final currentUserId in [null, '', '  ']) {
        expect(
          MvpRules.canAcceptQuestion(
            questionStatus: 'open',
            helperApproved: true,
            questionOwnerId: 'questioner',
            currentUserId: currentUserId,
          ),
          isFalse,
        );
      }
      for (final questionOwnerId in ['', '  ']) {
        expect(
          MvpRules.canAcceptQuestion(
            questionStatus: 'open',
            helperApproved: true,
            questionOwnerId: questionOwnerId,
            currentUserId: 'helper',
          ),
          isFalse,
        );
      }
    });

    test('종료되거나 알 수 없는 상태의 질문은 수락할 수 없다', () {
      for (final status in [
        'answered',
        'accepted',
        'cancelled',
        'expired',
        '',
      ]) {
        expect(
          MvpRules.canAcceptQuestion(
            questionStatus: status,
            helperApproved: true,
            questionOwnerId: 'questioner',
            currentUserId: 'helper',
          ),
          isFalse,
        );
      }
    });

    group('근거 URL 검증', () {
      const validUrls = [
        'https://example.com/info',
        'http://example.com',
        'HTTPS://EXAMPLE.COM/info?lang=ko#source',
        'https://sub-domain.example.com:8443/info',
        'https://example.com./info',
        'http://localhost:8080/source',
        'https://127.0.0.1/info',
        'https://[2001:db8::1]/info',
        'https://[::1]:8443/info',
        'https://xn--bcher-kva.example/source',
        'https://example.com/valid%20path?q=%ED%95%9C%EA%B5%AD',
      ];
      for (final url in validUrls) {
        test('정상 HTTP(S) URL 허용: $url', () {
          expect(MvpRules.isValidEvidenceUrl(url), isTrue);
        });
      }

      const invalidUrls = [
        '',
        'example.com/source',
        '//example.com/source',
        '/source',
        'javascript:alert(1)',
        'data:text/html,example',
        'file:///etc/passwd',
        'ftp://example.com/source',
        'mailto:person@example.com',
        'https:',
        'https://',
        'https:///source',
        'https:/example.com',
        'https:example.com',
        'https://?source=example.com',
        'https://#example.com',
        'https://user:password@example.com/source',
        'https://user@example.com/source',
        'https://@example.com/source',
        ' https://example.com',
        'https://example.com ',
        'https://exam ple.com',
        'https://example.com/a b',
        'https://example.com/\nsource',
        'https://example.com/\tsource',
        'https://example.com/\u0000source',
        'https://example.com/\u007fsource',
        'https://example.com/\u0085source',
        'https://example.com/\u00a0source',
        'https://example.com/\u200bsource',
        'https://example.com/\u202esource',
        'https://example.com/%0d%0aHeader:value',
        'https://example.com/%00source',
        'https://example.com/%7Fsource',
        'https://example.com/%invalid',
        'https://exa%6dple.com',
        r'https://example.com\@other.example/source',
        'https://.example.com',
        'https://example..com',
        'https://example.com..',
        'https://-example.com',
        'https://example-.com',
        'https://exam_ple.com',
        'https://example!.com',
        'https://.',
        'https://256.1.1.1',
        'https://127.1',
        'https://127.00.0.1',
        'https://2130706433',
        'https://[2001:db8:::1]',
        'https://[::1',
        'https://[]',
        'https://::1',
        'https://[::1]extra',
        'https://[::1]:',
        'https://example.com:',
        'https://example.com:abc',
        'https://example.com:-1',
        'https://example.com:0',
        'https://example.com:65536',
        'https://example.com:443:443',
      ];
      for (var index = 0; index < invalidUrls.length; index++) {
        test('잘못되거나 안전하지 않은 URL 거부 #$index', () {
          expect(
            MvpRules.isValidEvidenceUrl(invalidUrls[index]),
            isFalse,
            reason: invalidUrls[index],
          );
        });
      }

      test('DNS 호스트 및 레이블 길이 제한', () {
        expect(
          MvpRules.isValidEvidenceUrl('https://${'a' * 64}.example.com'),
          isFalse,
        );
        expect(
          MvpRules.isValidEvidenceUrl(
            'https://${List.filled(5, 'a' * 63).join('.')}',
          ),
          isFalse,
        );
      });
    });

    test('답변은 URL과 세 가지 확인 체크가 필요하다', () {
      expect(
        MvpRules.canSubmitAnswer(
          body: '공식 교통 사이트 기준으로 이 위치에서 구매할 수 있습니다.',
          evidenceUrls: const ['https://example.com/info'],
          confirmedEvidence: true,
          confirmedNoAiCopy: true,
          confirmedNoGuess: true,
        ),
        isTrue,
      );

      expect(
        MvpRules.canSubmitAnswer(
          body: '아마 될 것 같아요.',
          evidenceUrls: const [],
          confirmedEvidence: true,
          confirmedNoAiCopy: true,
          confirmedNoGuess: true,
        ),
        isFalse,
      );
    });

    test('한 개의 정상 URL이 있어도 다른 잘못된 URL을 함께 제출할 수 없다', () {
      expect(
        MvpRules.canSubmitAnswer(
          body: '공식 사이트에서 직접 확인한 충분한 길이의 답변입니다.',
          evidenceUrls: const [
            'https://example.com/source',
            'javascript:alert(1)',
          ],
          confirmedEvidence: true,
          confirmedNoAiCopy: true,
          confirmedNoGuess: true,
        ),
        isFalse,
      );
    });

    test('근거와 모든 확인 체크가 있어도 짧은 본문은 제출할 수 없다', () {
      expect(
        MvpRules.canSubmitAnswer(
          body: '  짧은 답변  ',
          evidenceUrls: const ['https://example.com/source'],
          confirmedEvidence: true,
          confirmedNoAiCopy: true,
          confirmedNoGuess: true,
        ),
        isFalse,
      );
    });

    test('세 가지 확인 체크가 각각 모두 필요하다', () {
      for (var unchecked = 0; unchecked < 3; unchecked++) {
        expect(
          MvpRules.canSubmitAnswer(
            body: '공식 사이트에서 직접 확인한 충분한 길이의 답변입니다.',
            evidenceUrls: const ['https://example.com/source'],
            confirmedEvidence: unchecked != 0,
            confirmedNoAiCopy: unchecked != 1,
            confirmedNoGuess: unchecked != 2,
          ),
          isFalse,
        );
      }
    });

    test('답변 채택 시 답변자 보상이 계산된다', () {
      final move = MvpRules.rewardHelper(helperBalance: 80, rewardPoints: 120);

      expect(move.helperBalance, 200);
      expect(move.transactionAmount, 120);
      expect(move.transactionType, 'reward');
    });
  });
}
