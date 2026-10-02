import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/api_service.dart';
import '../auth/auth_repository.dart';
import 'exchange_issue_repository.dart';

typedef ExchangeIssueScope = (String?, bool, bool);

ExchangeIssueScope exchangeIssueScope(AuthRepository auth) => (
  auth.currentUser?.id,
  auth.currentUser?.isAdmin ?? false,
  auth.currentUser?.isSuspended ?? false,
);

final exchangeIssueFeedProvider = Provider.autoDispose
    .family<ExchangeIssueFeed, ExchangeIssueView>((ref, view) {
      final feed = ExchangeIssueFeed(
        repository: ref.watch(exchangeIssueRepositoryProvider),
        auth: ref.watch(authRepositoryProvider),
        view: view,
      );
      ref.onDispose(feed.dispose);
      return feed;
    });

/// A page keeps only its authorized compact rows in memory.
class ExchangeIssueFeed extends ChangeNotifier {
  ExchangeIssueFeed({
    required ExchangeIssueRepository repository,
    required AuthRepository auth,
    required this.view,
  }) : _repository = repository,
       _auth = auth {
    _scope = exchangeIssueScope(auth);
    auth.addListener(_accountChanged);
    unawaited(refresh());
  }

  final ExchangeIssueRepository _repository;
  final AuthRepository _auth;
  final ExchangeIssueView view;
  late ExchangeIssueScope _scope;
  int _revision = 0;
  int _loadedPages = 1;
  bool _disposed = false;
  bool _failedMore = false;
  bool _denied = false;
  Future<void>? _request;
  List<ExchangeIssueEntry> items = const [];
  String? nextCursor;
  Object? error;
  bool isLoading = false;
  bool hasLoaded = false;

  bool get canRead =>
      !_disposed &&
      !_denied &&
      _scope.$1 != null &&
      !_scope.$3 &&
      (!view.isAdmin || _scope.$2);
  bool get accessDenied => !canRead;

  void _clear() {
    _revision++;
    _request = null;
    _loadedPages = 1;
    _failedMore = false;
    items = const [];
    nextCursor = null;
    error = null;
    isLoading = false;
    hasLoaded = false;
  }

  void _accountChanged() {
    if (_disposed || _scope == exchangeIssueScope(_auth)) return;
    _scope = exchangeIssueScope(_auth);
    _denied = false;
    _clear();
    notifyListeners();
    unawaited(refresh());
  }

  void denyAccess() {
    if (_disposed || _denied) return;
    _clear();
    _denied = true;
    notifyListeners();
  }

  void removeQuestion(String questionId) {
    if (_disposed) return;
    // A response started before a detail 404 must not restore that stale row.
    _revision++;
    _request = null;
    isLoading = false;
    items = List.unmodifiable(
      items.where((row) => row.questionId != questionId),
    );
    notifyListeners();
  }

  Future<void> refresh() => _load(more: false);
  Future<void> loadMore() =>
      nextCursor == null ? Future.value() : _load(more: true);
  Future<void> retry() => _load(more: _failedMore && nextCursor != null);

  Future<void> _load({required bool more}) {
    if (!canRead) return Future.value();
    if (_request != null) return _request!;
    final revision = _revision;
    final scope = _scope;
    final cursor = more ? nextCursor : null;
    final pageCount = more ? 1 : _loadedPages;
    isLoading = true;
    error = null;
    notifyListeners();
    final request = Future<void>.microtask(
      () => _fetch(
        more: more,
        revision: revision,
        scope: scope,
        cursor: cursor,
        pageCount: pageCount,
      ),
    );
    _request = request;
    return request;
  }

  bool _isCurrent(int revision, ExchangeIssueScope scope) =>
      !_disposed && revision == _revision && scope == exchangeIssueScope(_auth);

  Future<void> _fetch({
    required bool more,
    required int revision,
    required ExchangeIssueScope scope,
    required String? cursor,
    required int pageCount,
  }) async {
    if (!_isCurrent(revision, scope)) return;
    try {
      final fetched = <String, ExchangeIssueEntry>{};
      var next = cursor;
      var pages = 0;
      final seen = <String>{if (cursor != null) cursor};
      do {
        final page = await _repository.fetchPage(view: view, cursor: next);
        if (!_isCurrent(revision, scope)) return;
        for (final row in page.items) {
          if ((view == ExchangeIssueView.eligible &&
                  row is! EligibleExchange) ||
              (view != ExchangeIssueView.eligible &&
                  row is! ExchangeIssueRecord) ||
              (view.isAdmin && row is! AdminExchangeIssueRecord) ||
              (view == ExchangeIssueView.adminOpen &&
                  (row as ExchangeIssueRecord).status != 'open') ||
              (view == ExchangeIssueView.adminReviewed &&
                  (row as ExchangeIssueRecord).status != 'reviewed')) {
            throw const ApiException('선택한 기록 목록을 다시 확인해주세요.');
          }
          fetched[row.id] = row;
        }
        next = page.nextCursor;
        if (next != null && !seen.add(next)) {
          throw const ApiException(
            '목록을 처음부터 다시 확인해주세요.',
            code: 'INVALID_EXCHANGE_ISSUES_CURSOR',
          );
        }
        pages++;
      } while (pages < pageCount && next != null);
      if (!_isCurrent(revision, scope)) return;
      items = List.unmodifiable(
        {
          if (more)
            for (final row in items) row.id: row,
          ...fetched,
        }.values,
      );
      nextCursor = next;
      _loadedPages = more ? _loadedPages + pages : pages;
      hasLoaded = true;
      _failedMore = false;
    } catch (failure) {
      if (!_isCurrent(revision, scope)) return;
      if (exchangeIssueAccessFailure(failure)) {
        denyAccess();
        return;
      }
      error = failure;
      _failedMore =
          more &&
          !(failure is ApiException &&
              failure.code == 'INVALID_EXCHANGE_ISSUES_CURSOR');
    } finally {
      if (_isCurrent(revision, scope)) {
        isLoading = false;
        _request = null;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _clear();
    _auth.removeListener(_accountChanged);
    super.dispose();
  }
}
