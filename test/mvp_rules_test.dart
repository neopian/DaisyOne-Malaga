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
        ),
        isTrue,
      );
      expect(
        MvpRules.canAcceptQuestion(
          questionStatus: 'assigned',
          helperApproved: true,
        ),
        isFalse,
      );
      expect(
        MvpRules.canAcceptQuestion(
          questionStatus: 'open',
          helperApproved: false,
        ),
        isFalse,
      );
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

    test('답변 채택 시 답변자 보상이 계산된다', () {
      final move = MvpRules.rewardHelper(helperBalance: 80, rewardPoints: 120);

      expect(move.helperBalance, 200);
      expect(move.transactionAmount, 120);
      expect(move.transactionType, 'reward');
    });
  });
}
