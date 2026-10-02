import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo/city_catalog.g.dart';
import '../../core/services/api_service.dart';
import '../auth/auth_repository.dart';
import 'operations_repository.dart';

final operationsFeedProvider = Provider.autoDispose<OperationsFeed>((ref) {
  final feed = OperationsFeed(
    repository: ref.watch(operationsRepositoryProvider),
    auth: ref.watch(authRepositoryProvider),
  );
  ref.onDispose(feed.dispose);
  return feed;
});

/// Private operations data stays in memory for the lifetime of this page.
class OperationsFeed extends ChangeNotifier {
  OperationsFeed({
    required OperationsRepository repository,
    required AuthRepository auth,
  }) : _repository = repository,
       _auth = auth {
    _accountScope = _currentAccountScope;
    _auth.addListener(_accountChanged);
    unawaited(refresh());
  }

  final OperationsRepository _repository;
  final AuthRepository _auth;
  late (String?, bool, bool) _accountScope;
  int _revision = 0;
  int _loadedPages = 1;
  bool _disposed = false;
  bool _failedMore = false;
  Future<void>? _request;

  OperationsStatus status = OperationsStatus.open;
  TravelCity? city;
  List<OperationsQuestion> items = const [];
  OperationsSummary? summary;
  String? nextCursor;
  Object? error;
  bool isLoading = false;
  bool hasLoaded = false;

  (String?, bool, bool) get _currentAccountScope => (
    _auth.currentUser?.id,
    _auth.currentUser?.isAdmin ?? false,
    _auth.currentUser?.isSuspended ?? false,
  );

  bool get canRead =>
      _accountScope.$1 != null && _accountScope.$2 && !_accountScope.$3;

  bool get accessDenied =>
      !canRead ||
      (error is ApiException &&
          const [401, 403].contains((error as ApiException).status));

  void _clear() {
    _revision++;
    _request = null;
    _loadedPages = 1;
    _failedMore = false;
    items = const [];
    summary = null;
    nextCursor = null;
    error = null;
    isLoading = false;
    hasLoaded = false;
  }

  void _accountChanged() {
    if (_disposed || _accountScope == _currentAccountScope) return;
    _accountScope = _currentAccountScope;
    _clear();
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> selectStatus(OperationsStatus next) {
    if (_disposed || status == next) return Future.value();
    status = next;
    _clear();
    notifyListeners();
    return refresh();
  }

  Future<void> selectCity(TravelCity? next) {
    if (_disposed || city?.id == next?.id) return Future.value();
    city = next;
    _clear();
    notifyListeners();
    return refresh();
  }

  Future<void> refresh() => _load(more: false);

  Future<void> loadMore() =>
      nextCursor == null ? Future.value() : _load(more: true);

  Future<void> retry() => _load(more: _failedMore && nextCursor != null);

  Future<void> _load({required bool more}) {
    if (_disposed || !canRead) return Future.value();
    if (_request != null) return _request!;
    final revision = _revision;
    final scope = _accountScope;
    final requestedStatus = status;
    final requestedCity = city;
    final cursor = more ? nextCursor : null;
    final pageCount = more ? 1 : _loadedPages;
    isLoading = true;
    error = null;
    // Counts belong to a complete successful response, never a failed refresh.
    summary = null;
    notifyListeners();
    final request = Future<void>.microtask(
      () => _fetch(
        more: more,
        revision: revision,
        scope: scope,
        requestedStatus: requestedStatus,
        requestedCity: requestedCity,
        cursor: cursor,
        pageCount: pageCount,
      ),
    );
    _request = request;
    return request;
  }

  bool _isCurrent(int revision, (String?, bool, bool) scope) =>
      !_disposed && revision == _revision && scope == _currentAccountScope;

  Future<void> _fetch({
    required bool more,
    required int revision,
    required (String?, bool, bool) scope,
    required OperationsStatus requestedStatus,
    required TravelCity? requestedCity,
    required String? cursor,
    required int pageCount,
  }) async {
    if (!_isCurrent(revision, scope)) return;
    try {
      final fetched = <String, OperationsQuestion>{};
      var next = cursor;
      var pages = 0;
      OperationsSummary? fetchedSummary;
      final seenCursors = <String>{if (cursor != null) cursor};
      do {
        final page = await _repository.fetchPage(
          status: requestedStatus,
          city: requestedCity,
          cursor: next,
        );
        if (!_isCurrent(revision, scope)) return;
        for (final question in page.items) {
          if (question.status != requestedStatus ||
              (requestedCity != null &&
                  CityCatalog.findCity(question.country, question.city)?.id !=
                      requestedCity.id)) {
            throw const ApiException('선택한 조건의 목록을 다시 확인해주세요.');
          }
          fetched[question.id] = question;
        }
        fetchedSummary = page.summary;
        next = page.nextCursor;
        if (next != null && !seenCursors.add(next)) {
          throw const ApiException(
            '목록을 처음부터 다시 확인해주세요.',
            code: 'INVALID_OPERATIONS_CURSOR',
          );
        }
        pages++;
      } while (pages < pageCount && next != null);
      if (!_isCurrent(revision, scope)) return;
      items = List.unmodifiable(
        {
          if (more)
            for (final question in items) question.id: question,
          ...fetched,
        }.values,
      );
      summary = fetchedSummary;
      nextCursor = next;
      _loadedPages = more ? _loadedPages + pages : pages;
      hasLoaded = true;
      _failedMore = false;
    } catch (failure) {
      if (!_isCurrent(revision, scope)) return;
      if (failure is ApiException &&
          (const [401, 403, 404].contains(failure.status) ||
              failure.code == 'session_changed')) {
        items = const [];
        nextCursor = null;
        _loadedPages = 1;
        hasLoaded = false;
      }
      summary = null;
      error = failure;
      _failedMore =
          more &&
          !(failure is ApiException &&
              failure.code == 'INVALID_OPERATIONS_CURSOR');
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
