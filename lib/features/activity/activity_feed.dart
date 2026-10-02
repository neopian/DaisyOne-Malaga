import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/api_service.dart';
import '../../shared/models/question.dart';
import '../auth/auth_repository.dart';
import 'activity_repository.dart';

/// Invalidated by the shared foreground poller. Listening does not recreate a
/// feed or discard an already loaded page when the connection is interrupted.
final activityRefreshProvider = Provider<Object>((ref) => Object());

final activityFeedProvider = Provider.autoDispose
    .family<ActivityFeed, ActivityRole>((ref, role) {
      final feed = ActivityFeed(
        repository: ref.watch(activityRepositoryProvider),
        auth: ref.watch(authRepositoryProvider),
        role: role,
      );
      ref.listen(activityRefreshProvider, (_, _) => unawaited(feed.refresh()));
      ref.onDispose(feed.dispose);
      return feed;
    });

class ActivityFeed extends ChangeNotifier {
  ActivityFeed({
    required ActivityRepository repository,
    required AuthRepository auth,
    required this.role,
  }) : _repository = repository,
       _auth = auth,
       _owner = auth.currentUser?.id {
    _auth.addListener(_accountChanged);
    unawaited(refresh());
  }

  final ActivityRepository _repository;
  final AuthRepository _auth;
  final ActivityRole role;
  String? _owner;
  int _revision = 0;
  int _loadedPages = 1;
  bool _disposed = false;
  Future<void>? _request;
  bool _failedMore = false;

  ActivityView view = ActivityView.active;
  List<Question> items = const [];
  String? nextCursor;
  Object? error;
  bool isLoading = false;
  bool hasLoaded = false;

  void _clear() {
    _revision++;
    _request = null;
    _loadedPages = 1;
    items = const [];
    nextCursor = null;
    error = null;
    isLoading = false;
    hasLoaded = false;
    _failedMore = false;
  }

  void _accountChanged() {
    if (_disposed || _owner == _auth.currentUser?.id) return;
    _owner = _auth.currentUser?.id;
    _clear();
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> selectView(ActivityView next) {
    if (view == next || _disposed) return Future.value();
    view = next;
    _clear();
    return refresh();
  }

  Future<void> refresh() => _load(more: false);

  Future<void> loadMore() {
    if (nextCursor == null) return Future.value();
    return _load(more: true);
  }

  Future<void> retry() => _load(more: _failedMore && nextCursor != null);

  Future<void> _load({required bool more}) {
    if (_disposed || _owner == null) return Future.value();
    if (_request != null) return _request!;
    final revision = _revision;
    final owner = _owner;
    final requestedView = view;
    final cursor = more ? nextCursor : null;
    final pageCount = more ? 1 : _loadedPages;
    isLoading = true;
    error = null;
    notifyListeners();
    final request = Future<void>.microtask(
      () => _fetch(
        more: more,
        revision: revision,
        owner: owner,
        requestedView: requestedView,
        cursor: cursor,
        pageCount: pageCount,
      ),
    );
    _request = request;
    return request;
  }

  bool _isCurrent(int revision, String? owner) =>
      !_disposed && revision == _revision && owner == _auth.currentUser?.id;

  Future<void> _fetch({
    required bool more,
    required int revision,
    required String? owner,
    required ActivityView requestedView,
    required String? cursor,
    required int pageCount,
  }) async {
    if (!_isCurrent(revision, owner)) return;
    try {
      final fetched = <String, Question>{};
      var next = cursor;
      var pages = 0;
      final seenCursors = <String>{if (cursor != null) cursor};
      do {
        final page = await _repository.fetchPage(
          role: role,
          view: requestedView,
          cursor: next,
        );
        if (!_isCurrent(revision, owner)) return;
        for (final question in page.items) {
          // Defense in depth if a stale or malformed response names another
          // participant. The server remains the authority for visibility.
          final isParticipant = role == ActivityRole.traveler
              ? question.userId == owner
              : question.assignedHelperUserId == owner;
          if (isParticipant) fetched[question.id] = question;
        }
        next = page.nextCursor;
        if (next != null && !seenCursors.add(next)) {
          throw const ApiException('목록을 다시 확인해주세요.');
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
      _loadedPages = more ? _loadedPages + pages : pages;
      hasLoaded = true;
      _failedMore = false;
    } catch (failure) {
      if (!_isCurrent(revision, owner)) return;
      if (failure is ApiException &&
          (const [401, 403, 404].contains(failure.status) ||
              failure.code == 'session_changed')) {
        items = const [];
        nextCursor = null;
        _loadedPages = 1;
        hasLoaded = false;
      }
      error = failure;
      _failedMore =
          more &&
          !(failure is ApiException &&
              failure.code == 'INVALID_ACTIVITY_CURSOR');
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
