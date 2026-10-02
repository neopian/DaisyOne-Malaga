import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/exchange_issues/exchange_issue_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';

AppUser exchangeIssueUser({
  String id = 'participant',
  bool isAdmin = false,
  bool isSuspended = false,
}) => AppUser(
  id: id,
  email: '$id@example.test',
  name: '참여자',
  pointBalance: 0,
  isAdmin: isAdmin,
  isSuspended: isSuspended,
);

class ExchangeIssueTestAuth extends AuthRepository {
  ExchangeIssueTestAuth(super.client);

  AppUser? user = exchangeIssueUser();

  @override
  AppUser? get currentUser => user;

  void change(AppUser? next) {
    user = next;
    notifyListeners();
  }
}

Map<String, dynamic> eligibleExchangeRow(
  String questionId, {
  String role = 'traveler',
  String status = 'assigned',
  bool contentAvailable = true,
  String? ownIssueId,
}) => {
  'question_id': questionId,
  'role': role,
  'status': status,
  'content_available': contentAvailable,
  'title': contentAvailable ? '진행 $questionId' : null,
  'created_at': '2026-09-28T01:00:00.000000Z',
  'updated_at': '2026-10-02T03:00:00.000000Z',
  'own_issue_id': ownIssueId,
};

EligibleExchange eligibleExchange(
  String questionId, {
  String role = 'traveler',
  String status = 'assigned',
  bool contentAvailable = true,
  String? ownIssueId,
}) => EligibleExchange.fromMap(
  eligibleExchangeRow(
    questionId,
    role: role,
    status: status,
    contentAvailable: contentAvailable,
    ownIssueId: ownIssueId,
  ),
);

Map<String, dynamic> exchangeIssueRow(
  String id, {
  String questionId = 'question',
  String role = 'traveler',
  String status = 'open',
  String? details = '비공개 진행 내용',
}) => {
  'id': id,
  'question_id': questionId,
  'role': role,
  'reason': 'waiting_for_response',
  'details': details,
  'status': status,
  'created_at': '2026-09-28T01:00:00.000000Z',
  'reviewed_at': status == 'reviewed' ? '2026-10-02T03:00:00Z' : null,
};

ExchangeIssueRecord exchangeIssue(
  String id, {
  String questionId = 'question',
  String role = 'traveler',
  String status = 'open',
  String? details = '비공개 진행 내용',
}) => ExchangeIssueRecord.fromMap(
  exchangeIssueRow(
    id,
    questionId: questionId,
    role: role,
    status: status,
    details: details,
  ),
);

Map<String, dynamic> adminExchangeIssueRow(
  String id, {
  String questionId = 'question',
  String status = 'open',
  String? reviewNote,
}) => {
  ...exchangeIssueRow(id, questionId: questionId, status: status),
  'reporter_id': 'reporter',
  'other_participant_id': 'other-participant',
  'reviewed_by': status == 'reviewed' ? 'admin' : null,
  'review_note': reviewNote,
};

AdminExchangeIssueRecord adminExchangeIssue(
  String id, {
  String questionId = 'question',
  String status = 'open',
  String? reviewNote,
}) => AdminExchangeIssueRecord.fromMap(
  adminExchangeIssueRow(
    id,
    questionId: questionId,
    status: status,
    reviewNote: reviewNote,
  ),
);

class ExchangeIssueTestRepository extends ExchangeIssueRepository {
  ExchangeIssueTestRepository(super.client);

  final pageCalls = <({ExchangeIssueView view, String? cursor})>[];
  final eligibleCalls = <String>[];
  final ownCalls = <String>[];
  final createCalls =
      <({String questionId, ExchangeIssueReason reason, String details})>[];
  final reviewCalls = <({String id, String note})>[];

  Future<ExchangeIssuePageData> Function(ExchangeIssueView, String?)
  pageResponse = (_, _) async => const ExchangeIssuePageData(items: []);
  Future<EligibleExchange> Function(String) eligibleResponse = (id) async =>
      eligibleExchange(id);
  Future<ExchangeIssueRecord> Function(String) ownResponse = (id) async =>
      exchangeIssue(id);
  Future<String> Function(String, ExchangeIssueReason, String) createResponse =
      (_, _, _) async => 'created-issue';
  Future<void> Function(String, String) reviewResponse = (_, _) async {};

  @override
  Future<ExchangeIssuePageData> fetchPage({
    required ExchangeIssueView view,
    String? cursor,
  }) {
    pageCalls.add((view: view, cursor: cursor));
    return pageResponse(view, cursor);
  }

  @override
  Future<ExchangeIssueRecord> fetchOwn(String id) {
    ownCalls.add(id);
    return ownResponse(id);
  }

  @override
  Future<EligibleExchange> fetchEligible(String questionId) {
    eligibleCalls.add(questionId);
    return eligibleResponse(questionId);
  }

  @override
  Future<String> create({
    required String questionId,
    required ExchangeIssueReason reason,
    required String details,
  }) {
    createCalls.add((questionId: questionId, reason: reason, details: details));
    return createResponse(questionId, reason, details);
  }

  @override
  Future<void> review(String id, String note) {
    reviewCalls.add((id: id, note: note));
    return reviewResponse(id, note);
  }
}
