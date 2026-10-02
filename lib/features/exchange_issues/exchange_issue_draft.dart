import 'package:flutter/foundation.dart';

import '../../core/services/api_service.dart';
import '../auth/auth_repository.dart';
import 'exchange_issue_feed.dart';
import 'exchange_issue_repository.dart';

/// Drafts belong to the account and page, not a transient dialog route. Closing
/// a dialog does not change a pending intent or turn its result into a new post.
class ExchangeIssueDraft extends ChangeNotifier {
  ExchangeIssueDraft({
    required ExchangeIssueRepository repository,
    required AuthRepository auth,
    required this.questionId,
    this.issueId,
    this.adminRecord,
    required this.onAccessDenied,
    this.onMissing,
  }) : _repository = repository,
       _auth = auth,
       _scope = exchangeIssueScope(auth) {
    _auth.addListener(_accountChanged);
  }

  final ExchangeIssueRepository _repository;
  final AuthRepository _auth;
  final ExchangeIssueScope _scope;
  final String questionId;
  final VoidCallback onAccessDenied;
  final VoidCallback? onMissing;
  AdminExchangeIssueRecord? adminRecord;
  String? issueId;
  ExchangeIssueRecord? record;
  ExchangeIssueReason reason = ExchangeIssueReason.waitingForResponse;
  String text = '';
  Object? error;
  bool busy = false;
  bool denied = false;
  bool missing = false;
  bool reviewed = false;
  bool actionUnavailable = false;
  bool _disposed = false;
  int _revision = 0;
  (ExchangeIssueReason, String)? _intent;
  Future<void>? _request;

  bool get isAdmin => adminRecord != null;
  bool get frozen => _intent != null;
  bool get canEdit =>
      !denied &&
      !busy &&
      !frozen &&
      (isAdmin ? !reviewed && adminRecord?.status == 'open' : issueId == null);
  bool get canSubmit =>
      !denied &&
      !busy &&
      !actionUnavailable &&
      (isAdmin ? !reviewed && adminRecord?.status == 'open' : issueId == null);

  void _accountChanged() {
    if (_scope != exchangeIssueScope(_auth)) revoke();
  }

  void revoke() {
    if (_disposed || denied) return;
    _revision++;
    _request = null;
    denied = true;
    busy = false;
    text = '';
    _intent = null;
    error = null;
    record = null;
    adminRecord = null;
    issueId = null;
    notifyListeners();
  }

  bool _current(int revision) =>
      !_disposed &&
      !denied &&
      revision == _revision &&
      _scope == exchangeIssueScope(_auth);

  Future<void> load() => _run(submit: false);
  Future<void> submit() => _run(submit: true);

  Future<void> _run({required bool submit}) {
    if (_request != null) return _request!;
    if (_disposed || denied || (submit && !canSubmit)) return Future.value();
    if (_scope.$1 == null || _scope.$3 || (isAdmin && !_scope.$2)) {
      revoke();
      return Future.value();
    }
    if (submit && (text.trim().length > 1000 || text.contains('\u0000'))) {
      error = const ApiException(
        '내용은 1000자 이내로 입력해주세요.',
        code: 'VALIDATION',
        status: 400,
      );
      notifyListeners();
      return Future.value();
    }
    if (!submit && (isAdmin || issueId == null)) return Future.value();
    if (submit) _intent ??= (reason, text.trim());
    final revision = _revision;
    busy = true;
    error = null;
    notifyListeners();
    final request = Future<void>.microtask(() => _perform(submit, revision));
    _request = request;
    return request;
  }

  Future<void> _perform(bool submit, int revision) async {
    if (!_current(revision)) return;
    try {
      if (submit && isAdmin) {
        await _repository.review(adminRecord!.id, _intent!.$2);
        if (!_current(revision)) return;
        reviewed = true;
        text = '';
      } else {
        if (submit) {
          final id = await _repository.create(
            questionId: questionId,
            reason: _intent!.$1,
            details: _intent!.$2,
          );
          if (!_current(revision)) return;
          issueId = id;
          // Acknowledged creation never posts again, even if direct GET fails.
          text = '';
        }
        final result = await _repository.fetchOwn(issueId!);
        if (!_current(revision)) return;
        if (result.id != issueId || result.questionId != questionId) {
          throw const ApiException('기록 참조를 확인하지 못했습니다.');
        }
        record = result;
      }
    } catch (failure) {
      if (!_current(revision)) return;
      if (failure is ApiException && failure.status == 404) {
        missing = true;
        revoke();
        onMissing?.call();
        return;
      }
      if (exchangeIssueAccessFailure(failure)) {
        revoke();
        onAccessDenied();
        return;
      }
      error = failure;
      if (failure is ApiException &&
          const [
            'ISSUE_ALREADY_EXISTS',
            'EXCHANGE_NOT_ELIGIBLE',
            'ISSUE_ALREADY_REVIEWED',
          ].contains(failure.code)) {
        actionUnavailable = true;
      }
      // Only an explicit validation rejection allows changing an unsent draft.
      // Timeouts, conflicts and unknown replies must keep the original intent.
      if (failure is ApiException &&
          const [400, 422].contains(failure.status) &&
          issueId == null) {
        _intent = null;
      }
    } finally {
      if (_current(revision)) {
        busy = false;
        _request = null;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _auth.removeListener(_accountChanged);
    text = '';
    _intent = null;
    record = null;
    adminRecord = null;
    super.dispose();
  }
}
