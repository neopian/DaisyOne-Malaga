class MvpRules {
  static bool canCreateQuestion({
    required int pointBalance,
    required int rewardPoints,
  }) {
    return rewardPoints > 0 && pointBalance >= rewardPoints;
  }

  static bool canAcceptQuestion({
    required String questionStatus,
    required bool helperApproved,
  }) {
    return helperApproved && questionStatus == 'open';
  }

  static bool canSubmitAnswer({
    required String body,
    required List<String> evidenceUrls,
    required bool confirmedEvidence,
    required bool confirmedNoAiCopy,
    required bool confirmedNoGuess,
  }) {
    final hasBody = body.trim().length >= 10;
    final hasEvidence = evidenceUrls.any(
      (url) => Uri.tryParse(url)?.hasScheme ?? false,
    );
    return hasBody &&
        hasEvidence &&
        confirmedEvidence &&
        confirmedNoAiCopy &&
        confirmedNoGuess;
  }

  static PointMove holdReward({
    required int questionerBalance,
    required int rewardPoints,
  }) {
    if (!canCreateQuestion(
      pointBalance: questionerBalance,
      rewardPoints: rewardPoints,
    )) {
      throw StateError('포인트가 부족합니다.');
    }
    return PointMove(
      questionerBalance: questionerBalance - rewardPoints,
      helperBalance: null,
      transactionAmount: -rewardPoints,
      transactionType: 'hold',
    );
  }

  static PointMove rewardHelper({
    required int helperBalance,
    required int rewardPoints,
  }) {
    if (rewardPoints <= 0) {
      throw StateError('보상 포인트는 0보다 커야 합니다.');
    }
    return PointMove(
      questionerBalance: null,
      helperBalance: helperBalance + rewardPoints,
      transactionAmount: rewardPoints,
      transactionType: 'reward',
    );
  }
}

class PointMove {
  const PointMove({
    required this.questionerBalance,
    required this.helperBalance,
    required this.transactionAmount,
    required this.transactionType,
  });

  final int? questionerBalance;
  final int? helperBalance;
  final int transactionAmount;
  final String transactionType;
}
