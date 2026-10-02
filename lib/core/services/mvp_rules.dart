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
    required String questionOwnerId,
    required String? currentUserId,
  }) {
    return helperApproved &&
        questionStatus == 'open' &&
        questionOwnerId.trim().isNotEmpty &&
        currentUserId != null &&
        currentUserId.trim().isNotEmpty &&
        currentUserId.trim() != questionOwnerId.trim();
  }

  /// The same allowlist is used when adding, submitting and opening evidence.
  /// Do not let Uri's normalization silently repair ambiguous authorities.
  static bool isValidEvidenceUrl(String url) {
    if (url.isEmpty ||
        RegExp(
          r'[\s\x00-\x20\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
        ).hasMatch(url) ||
        url.contains('\\') ||
        RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(url) ||
        RegExp(
          r'%(?:0[0-9a-f]|1[0-9a-f]|7f)',
          caseSensitive: false,
        ).hasMatch(url)) {
      return false;
    }

    final authorityMatch = RegExp(
      r'^https?://([^/?#]+)',
      caseSensitive: false,
    ).firstMatch(url);
    if (authorityMatch == null) return false;
    final authority = authorityMatch.group(1)!;
    if (authority.contains('@') || authority.contains('%')) return false;

    try {
      final uri = Uri.parse(url);
      if (!uri.hasAuthority || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
        return false;
      }

      final String host;
      final String portSuffix;
      if (authority.startsWith('[')) {
        final closingBracket = authority.indexOf(']');
        if (closingBracket == -1) return false;
        host = authority.substring(1, closingBracket);
        Uri.parseIPv6Address(host);
        portSuffix = authority.substring(closingBracket + 1);
      } else {
        final colon = authority.indexOf(':');
        host = colon == -1 ? authority : authority.substring(0, colon);
        portSuffix = colon == -1 ? '' : authority.substring(colon);
        if (!_isValidEvidenceHost(host)) return false;
      }

      if (portSuffix.isNotEmpty) {
        if (!RegExp(r'^:[0-9]+$').hasMatch(portSuffix)) return false;
        final port = int.tryParse(portSuffix.substring(1));
        if (port == null || port < 1 || port > 65535) return false;
      }
      return true;
    } on FormatException {
      return false;
    }
  }

  static bool _isValidEvidenceHost(String host) {
    final domain = host.endsWith('.')
        ? host.substring(0, host.length - 1)
        : host;
    if (domain.isEmpty || domain.length > 253) return false;
    final labels = domain.split('.');
    if (RegExp(r'^[0-9.]+$').hasMatch(domain)) {
      return labels.length == 4 &&
          labels.every((label) {
            final octet = int.tryParse(label);
            return octet != null &&
                octet >= 0 &&
                octet <= 255 &&
                (label.length == 1 || !label.startsWith('0'));
          });
    }
    return labels.every(
      (label) => RegExp(
        r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
        caseSensitive: false,
      ).hasMatch(label),
    );
  }

  static bool canSubmitAnswer({
    required String body,
    required List<String> evidenceUrls,
    required bool confirmedEvidence,
    required bool confirmedNoAiCopy,
    required bool confirmedNoGuess,
  }) {
    final hasBody = body.trim().length >= 10;
    final hasEvidence =
        evidenceUrls.isNotEmpty && evidenceUrls.every(isValidEvidenceUrl);
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
