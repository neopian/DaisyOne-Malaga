import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/api_service.dart';
import '../../shared/models/question.dart';
import '../auth/auth_repository.dart';
import '../helper_application/helper_repository.dart';
import 'guide_discovery_repository.dart';

final guideDiscoveryRefreshProvider = Provider<Object>((ref) => Object());

final guideDiscoveryFeedProvider = Provider.autoDispose<GuideDiscoveryFeed>((
  ref,
) {
  final feed = GuideDiscoveryFeed(
    repository: ref.watch(guideDiscoveryRepositoryProvider),
    auth: ref.watch(authRepositoryProvider),
    approved:
        ref.read(helperApplicationProvider).asData?.value?.isApproved == true,
  );
  ref.listen(helperApplicationProvider, (_, next) {
    // A refreshing application can still have its last approved value. Only a
    // resolved authorization change revokes the in-memory list here.
    if (next.asData != null) {
      feed.setApproved(next.asData!.value?.isApproved == true);
    } else if (next.error case final ApiException error
        when error.status == 401 || error.status == 403) {
      feed.setApproved(false);
    }
  });
  ref.listen(
    guideDiscoveryRefreshProvider,
    (_, _) => unawaited(feed.refresh()),
  );
  ref.onDispose(feed.dispose);
  return feed;
});

class GuideDiscoveryFeed extends ChangeNotifier {
  GuideDiscoveryFeed({
    required GuideDiscoveryRepository repository,
    required AuthRepository auth,
    required bool approved,
  }) : _repository = repository,
       _auth = auth,
       _approved = approved,
       _owner = auth.currentUser?.id,
       _suspended = auth.currentUser?.isSuspended == true {
    _auth.addListener(_accountChanged);
    unawaited(refresh());
  }

  final GuideDiscoveryRepository _repository;
  final AuthRepository _auth;
  String? _owner;
  bool _approved;
  bool _suspended;
  int _revision = 0;
  int _loadedPages = 1;
  bool _disposed = false;
  Future<void>? _request;
  bool _failedMore = false;
  bool _loadingMore = false;
  Set<String> _usedCursors = {};

  List<Question> items = const [];
  String? nextCursor;
  Object? error;
  bool isLoading = false;
  bool hasLoaded = false;
  bool get failedMore => error != null && _failedMore;
  bool get isLoadingMore => isLoading && _loadingMore;

  void _clear() {
    _revision++;
    _request = null;
    _loadedPages = 1;
    _usedCursors = {};
    items = const [];
    nextCursor = null;
    error = null;
    isLoading = false;
    hasLoaded = false;
    _failedMore = false;
    _loadingMore = false;
  }

  void _accountChanged() {
    if (_disposed) return;
    final owner = _auth.currentUser?.id;
    final suspended = _auth.currentUser?.isSuspended == true;
    if (_owner == owner && _suspended == suspended) return;
    if (_owner != owner) _approved = false;
    _owner = owner;
    _suspended = suspended;
    _clear();
    notifyListeners();
    unawaited(refresh());
  }

  void setApproved(bool approved) {
    if (_disposed || _approved == approved) return;
    _approved = approved;
    _clear();
    notifyListeners();
    if (approved) unawaited(refresh());
  }

  Future<void> refresh() => _load(more: false);

  /// A detail action may have changed eligibility while a poll was in flight.
  /// Keep the loaded page window, but never accept that earlier response.
  Future<void> refreshAfterDetail() {
    if (_disposed) return Future.value();
    _revision++;
    _request = null;
    return refresh();
  }

  Future<void> loadMore() =>
      nextCursor == null ? Future.value() : _load(more: true);

  Future<void> retry() => _load(more: _failedMore && nextCursor != null);

  Future<void> _load({required bool more}) {
    if (_disposed || _owner == null || !_approved || _suspended) {
      return Future.value();
    }
    if (_request != null) return _request!;
    final revision = _revision;
    final owner = _owner!;
    final cursor = more ? nextCursor : null;
    final pageCount = more ? 1 : _loadedPages;
    isLoading = true;
    _loadingMore = more;
    error = null;
    final request = Future<void>.microtask(
      () => _fetch(
        more: more,
        revision: revision,
        owner: owner,
        cursor: cursor,
        pageCount: pageCount,
      ),
    );
    _request = request;
    notifyListeners();
    return request;
  }

  bool _isCurrent(int revision, String owner) =>
      !_disposed &&
      revision == _revision &&
      owner == _auth.currentUser?.id &&
      _approved &&
      _auth.currentUser?.isSuspended != true;

  bool _isTransient(Object failure) =>
      failure is ApiException &&
      (failure.status == 408 ||
          failure.status == 429 ||
          (failure.status != null && failure.status! >= 500) ||
          (failure.status == null &&
              const [
                'connection',
                'timeout',
                'request_failed',
              ].contains(failure.code)));

  Future<void> _fetch({
    required bool more,
    required int revision,
    required String owner,
    required String? cursor,
    required int pageCount,
  }) async {
    if (!_isCurrent(revision, owner)) return;
    try {
      final fetched = <String, Question>{};
      final usedCursors = <String>{if (more) ..._usedCursors};
      var next = cursor;
      var pages = 0;
      do {
        if (next != null) usedCursors.add(next);
        final page = await _repository.fetchPage(cursor: next);
        if (!_isCurrent(revision, owner)) return;
        for (final question in page.items) {
          // Region, escrow, and visibility remain server-authoritative. These
          // checks only discard obviously stale or mis-scoped summaries.
          if (question.userId != owner &&
              question.isOpen &&
              question.assignedHelperUserId == null) {
            fetched[question.id] = question;
          }
        }
        next = page.nextCursor;
        if (next != null && usedCursors.contains(next)) {
          throw const ApiException(
            '목록을 처음부터 다시 확인해주세요.',
            code: 'INVALID_DISCOVERY_CURSOR',
          );
        }
        pages++;
      } while (pages < pageCount && next != null);
      if (!_isCurrent(revision, owner)) return;
      items = List.unmodifiable(
        {
          if (more)
            for (final question in items) question.id: question,
          ...fetched,
        }.values,
      );
      nextCursor = next;
      _usedCursors = usedCursors;
      _loadedPages = more ? _loadedPages + pages : pages;
      hasLoaded = true;
      _failedMore = false;
    } catch (failure) {
      if (!_isCurrent(revision, owner)) return;
      if (!_isTransient(failure)) {
        items = const [];
        nextCursor = null;
        _loadedPages = 1;
        _usedCursors = {};
        hasLoaded = false;
      }
      error = failure;
      _failedMore = more && _isTransient(failure);
    } finally {
      if (_isCurrent(revision, owner)) {
        isLoading = false;
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
    super.dispose();
  }
}
