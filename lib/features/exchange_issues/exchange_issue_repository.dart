import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/api_service.dart';

enum ExchangeIssueView {
  eligible('기록할 진행'),
  mine('내 기록'),
  adminOpen('기록됨'),
  adminReviewed('검토 표시됨');

  const ExchangeIssueView(this.label);
  final String label;
  bool get isAdmin => this == adminOpen || this == adminReviewed;
}

enum ExchangeIssueReason {
  waitingForResponse('waiting_for_response', '응답을 기다리고 있어요'),
  answerProblem('answer_problem', '답변에 문제가 있어요'),
  cannotContinue('cannot_continue', '진행을 계속하기 어려워요'),
  other('other', '기타');

  const ExchangeIssueReason(this.code, this.label);
  final String code;
  final String label;
}

const exchangeIssueDisclosure =
    '운영자가 확인할 수 있는 비공개 기록입니다. 답변이나 처리 시간을 보장하지 않으며, 질문 상태와 가상 포인트는 변경되지 않습니다.';
const _invalidResponse = ApiException('진행 문제 기록을 확인하지 못했어요. 다시 시도해주세요.');

String _text(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! String || value.trim().isEmpty) throw _invalidResponse;
  return value;
}

String? _optionalText(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value != null && value is! String) throw _invalidResponse;
  return value as String?;
}

DateTime _date(Map<String, dynamic> map, String key) {
  final date = DateTime.tryParse(_text(map, key));
  if (date == null) throw _invalidResponse;
  return date;
}

String _role(Map<String, dynamic> map) {
  final role = _text(map, 'role');
  if (!const ['traveler', 'guide'].contains(role)) throw _invalidResponse;
  return role;
}

sealed class ExchangeIssueEntry {
  String get id;
  String get questionId;
  String get role;
  String get roleLabel => role == 'traveler' ? '여행자' : '가이드';
}

class EligibleExchange extends ExchangeIssueEntry {
  EligibleExchange.fromMap(Map<String, dynamic> map)
    : questionId = _text(map, 'question_id'),
      role = _role(map),
      status = _text(map, 'status'),
      contentAvailable = map['content_available'] == true,
      title = map['content_available'] == true
          ? _optionalText(map, 'title')
          : null,
      createdAt = _date(map, 'created_at'),
      updatedAt = _date(map, 'updated_at'),
      ownIssueId = _optionalText(map, 'own_issue_id') {
    if (map['content_available'] is! bool ||
        !const ['assigned', 'answered'].contains(status)) {
      throw _invalidResponse;
    }
  }

  @override
  String get id => questionId;
  @override
  final String questionId;
  @override
  final String role;
  final String status;
  final String? title;
  final bool contentAvailable;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? ownIssueId;
}

class ExchangeIssueRecord extends ExchangeIssueEntry {
  ExchangeIssueRecord.fromMap(Map<String, dynamic> map)
    : id = _text(map, 'id'),
      questionId = _text(map, 'question_id'),
      role = _role(map),
      reason = ExchangeIssueReason.values.firstWhere(
        (reason) => reason.code == map['reason'],
        orElse: () => throw _invalidResponse,
      ),
      details = _optionalText(map, 'details'),
      status = _text(map, 'status'),
      createdAt = _date(map, 'created_at'),
      reviewedAt = map['reviewed_at'] == null
          ? null
          : _date(map, 'reviewed_at') {
    if (!const ['open', 'reviewed'].contains(status)) throw _invalidResponse;
  }

  @override
  final String id;
  @override
  final String questionId;
  @override
  final String role;
  final ExchangeIssueReason reason;
  final String? details;
  final String status;
  final DateTime createdAt;
  final DateTime? reviewedAt;
  String get statusLabel => status == 'open' ? '기록됨' : '검토 표시됨';
}

/// Admin-only metadata is never part of a participant record or editor.
class AdminExchangeIssueRecord extends ExchangeIssueRecord {
  AdminExchangeIssueRecord.fromMap(super.map)
    : reporterId = _text(map, 'reporter_id'),
      otherParticipantId = _text(map, 'other_participant_id'),
      reviewedBy = _optionalText(map, 'reviewed_by'),
      reviewNote = _optionalText(map, 'review_note'),
      super.fromMap();

  final String reporterId;
  final String otherParticipantId;
  final String? reviewedBy;
  final String? reviewNote;
}

class ExchangeIssuePageData {
  const ExchangeIssuePageData({required this.items, this.nextCursor});
  final List<ExchangeIssueEntry> items;
  final String? nextCursor;
}

final exchangeIssueRepositoryProvider = Provider<ExchangeIssueRepository>(
  (ref) => ExchangeIssueRepository(ref.watch(apiClientProvider)),
);

class ExchangeIssueRepository {
  const ExchangeIssueRepository(this._client);
  final ApiClient _client;

  Future<ExchangeIssuePageData> fetchPage({
    required ExchangeIssueView view,
    String? cursor,
  }) async {
    final path = Uri(
      path: switch (view) {
        ExchangeIssueView.eligible => 'exchange-issues/eligible',
        ExchangeIssueView.mine => 'exchange-issues',
        _ => 'admin/exchange-issues',
      },
      queryParameters: {
        if (view.isAdmin)
          'status': view == ExchangeIssueView.adminOpen ? 'open' : 'reviewed',
        if (cursor != null) 'cursor': cursor,
      },
    ).toString();
    final response = await _client.getMap(path);
    final rows = response['items'];
    final next = response['next_cursor'];
    if (rows is! List || (next != null && (next is! String || next.isEmpty))) {
      throw _invalidResponse;
    }
    return ExchangeIssuePageData(
      items: List.unmodifiable(
        rows.map((raw) {
          final row = ApiClient.asMap(raw);
          return switch (view) {
            ExchangeIssueView.eligible => EligibleExchange.fromMap(row),
            ExchangeIssueView.mine => ExchangeIssueRecord.fromMap(row),
            _ => AdminExchangeIssueRecord.fromMap(row),
          };
        }),
      ),
      nextCursor: next as String?,
    );
  }

  Future<ExchangeIssueRecord> fetchOwn(String id) async =>
      ExchangeIssueRecord.fromMap(
        await _client.getMap('exchange-issues/${Uri.encodeComponent(id)}'),
      );

  Future<EligibleExchange> fetchEligible(String questionId) async =>
      EligibleExchange.fromMap(
        await _client.getMap(
          'exchange-issues/eligible/${Uri.encodeComponent(questionId)}',
        ),
      );

  Future<String> create({
    required String questionId,
    required ExchangeIssueReason reason,
    required String details,
  }) async {
    final result = ApiClient.asMap(
      await _client.mutate(
        'exchange-issues',
        body: {
          'question_id': questionId,
          'reason': reason.code,
          if (details.trim().isNotEmpty) 'details': details.trim(),
        },
      ),
    );
    return _text(result, 'id');
  }

  Future<void> review(String id, String note) async {
    final result = ApiClient.asMap(
      await _client.mutate(
        'admin/exchange-issues/${Uri.encodeComponent(id)}/review',
        body: {if (note.trim().isNotEmpty) 'note': note.trim()},
      ),
    );
    if (result['ok'] != true) throw _invalidResponse;
  }
}

bool exchangeIssueAccessFailure(Object? failure) =>
    failure is ApiException &&
    (const [401, 403].contains(failure.status) ||
        failure.code == 'session_changed');

String exchangeIssueErrorText(Object error) => switch (error) {
  ApiException(code: 'ISSUE_ALREADY_EXISTS') =>
    '이 질문에 이미 내 기록이 있습니다. 내 기록 목록을 새로고침해 확인해주세요.',
  ApiException(code: 'EXCHANGE_NOT_ELIGIBLE') =>
    '현재 이 진행에는 새 기록을 남길 수 없습니다. 목록을 새로고침해주세요.',
  ApiException(code: 'ISSUE_ALREADY_REVIEWED') =>
    '이미 검토 표시된 기록입니다. 목록을 새로고침해 확인해주세요.',
  ApiException(code: 'ISSUE_LIMIT') => '기록 요청이 많습니다. 잠시 후 다시 시도해주세요.',
  ApiException(code: 'PAYLOAD_TOO_LARGE') =>
    '기록 내용이 너무 큽니다. 추가 내용이나 내부 메모를 1000자 이내로 줄여주세요.',
  ApiException(code: 'VALIDATION') =>
    '입력 내용을 확인해주세요. 추가 내용이나 내부 메모는 1000자 이내로 입력해주세요.',
  ApiException(code: 'INVALID_EXCHANGE_ISSUES_CURSOR') => '목록을 처음부터 다시 확인해주세요.',
  ApiException(status: 404) => '기록을 찾을 수 없습니다. 목록을 새로고침해 확인해주세요.',
  ApiException(status: 401) ||
  ApiException(status: 403) => '이 기록에 접근할 수 없습니다. 로그인과 계정 권한을 확인해주세요.',
  _ => '요청 결과를 확인하지 못했습니다. 연결을 확인한 뒤 다시 시도해주세요.',
};
