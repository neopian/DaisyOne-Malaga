import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/activity/activity_feed.dart';
import 'package:local_qa_concierge/features/activity/activity_repository.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:local_qa_concierge/shared/models/question.dart';

const activityUser = AppUser(
  id: 'owner',
  email: 'owner@example.test',
  name: '여행자',
  pointBalance: 1000,
  isAdmin: false,
);

class ActivityTestAuth extends AuthRepository {
  ActivityTestAuth(super.client);
  AppUser? user = activityUser;
  @override
  AppUser? get currentUser => user;
  void change(AppUser? next) {
    user = next;
    notifyListeners();
  }
}

Question activityQuestion(
  String id, {
  String owner = 'owner',
  String status = 'open',
}) => Question.fromMap({
  'id': id,
  'user_id': owner,
  'assigned_helper_user_id': 'owner',
  'title': '질문 $id',
  'country': 'France',
  'city': 'Paris',
  'reward_points': 100,
  'status': status,
  'created_at': '2026-10-02T00:00:00Z',
});

class ActivityTestRepository extends ActivityRepository {
  ActivityTestRepository(super.client);
  final calls = <({ActivityRole role, ActivityView view, String? cursor})>[];
  Future<ActivityPageData> Function(ActivityRole, ActivityView, String?)
  response = (_, _, _) async => const ActivityPageData(items: []);
  @override
  Future<ActivityPageData> fetchPage({
    required ActivityRole role,
    required ActivityView view,
    String? cursor,
  }) {
    calls.add((role: role, view: view, cursor: cursor));
    return response(role, view, cursor);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'activity API uses participant role/view and safely encodes opaque cursor',
    () async {
      late Uri requested;
      final client = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 'question',
                  'user_id': 'owner',
                  'title': 'Text summary',
                  'status': 'assigned',
                },
              ],
              'next_cursor': 'next-page',
            }),
            200,
          );
        }),
      )..token = 'session';
      addTearDown(client.dispose);
      final page = await ActivityRepository(client).fetchPage(
        role: ActivityRole.guide,
        view: ActivityView.active,
        cursor: 'opaque+/=&value',
      );
      expect(requested.path, '/api/activity/questions');
      expect(requested.queryParameters, {
        'role': 'guide',
        'view': 'active',
        'cursor': 'opaque+/=&value',
      });
      expect(page.nextCursor, 'next-page');
      expect(page.items.single.title, 'Text summary');
      expect(page.items.single.body, isEmpty);
      expect(page.items.single.images, isEmpty);
    },
  );

  test('malformed page is an error rather than a false empty result', () async {
    final client = ApiClient(
      baseUrl: 'https://example.test/api',
      client: MockClient(
        (_) async => http.Response('{"items":null,"next_cursor":null}', 200),
      ),
    )..token = 'session';
    addTearDown(client.dispose);
    await expectLater(
      ActivityRepository(
        client,
      ).fetchPage(role: ActivityRole.traveler, view: ActivityView.active),
      throwsA(isA<ApiException>()),
    );
  });

  test(
    'recovery merges own recent active/history summaries and rejects a changed account',
    () async {
      final requested = <Uri>[];
      final client =
          ApiClient(
              baseUrl: 'https://example.test/api',
              client: MockClient((request) async {
                requested.add(request.url);
                final history =
                    request.url.queryParameters['view'] == 'history';
                return http.Response(
                  jsonEncode({
                    'items': [
                      {
                        'id': history ? 'newer' : 'older',
                        'user_id': 'owner',
                        'created_at': history
                            ? '2026-10-02T03:00:00Z'
                            : '2026-10-02T01:00:00Z',
                      },
                      {
                        'id': 'foreign',
                        'user_id': 'another',
                        'created_at': '2026-10-02T05:00:00Z',
                      },
                    ],
                    'next_cursor': null,
                  }),
                  200,
                );
              }),
            )
            ..token = 'session'
            ..userId = 'owner';
      addTearDown(client.dispose);
      final items = await ActivityRepository(client).fetchRecentOwnQuestions();
      expect(items.map((q) => q.id), ['newer', 'older']);
      expect(
        requested.map((u) => u.queryParameters['role']),
        everyElement('traveler'),
      );
      expect(requested.map((u) => u.queryParameters['view']).toSet(), {
        'active',
        'history',
      });

      final waiting = Completer<http.Response>();
      final changed =
          ApiClient(
              baseUrl: 'https://example.test/api',
              client: MockClient((_) => waiting.future),
            )
            ..token = 'first'
            ..userId = 'owner';
      addTearDown(changed.dispose);
      final result = ActivityRepository(changed).fetchRecentOwnQuestions();
      final expectation = expectLater(
        result,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'session_changed'),
        ),
      );
      changed.token = 'second';
      changed.userId = 'another';
      waiting.complete(http.Response('{"items":[],"next_cursor":null}', 200));
      await expectation;
    },
  );

  late ApiClient client;
  late ActivityTestAuth auth;
  late ActivityTestRepository repository;
  setUp(() {
    client = ApiClient(baseUrl: 'https://example.test/api');
    auth = ActivityTestAuth(client);
    repository = ActivityTestRepository(client);
  });
  tearDown(() {
    auth.dispose();
    client.dispose();
  });

  ActivityFeed makeFeed() {
    final feed = ActivityFeed(
      repository: repository,
      auth: auth,
      role: ActivityRole.traveler,
    );
    addTearDown(feed.dispose);
    return feed;
  }

  test(
    'paging retry preserves prior rows, deduplicates IDs and prevents double fetch',
    () async {
      repository.response = (_, _, _) async => ActivityPageData(
        items: [activityQuestion('first')],
        nextCursor: 'cursor',
      );
      final feed = makeFeed();
      await feed.refresh();
      final delayed = Completer<ActivityPageData>();
      repository.response = (_, _, _) => delayed.future;
      final first = feed.loadMore();
      final duplicate = feed.loadMore();
      await Future<void>.delayed(Duration.zero);
      expect(repository.calls, hasLength(2));
      expect(identical(first, duplicate), isTrue);
      delayed.completeError(const ApiException('offline', code: 'connection'));
      await first;
      expect(feed.items.map((q) => q.id), ['first']);
      expect(feed.nextCursor, 'cursor');
      expect(feed.error, isNotNull);
      repository.response = (_, _, _) async => ActivityPageData(
        items: [activityQuestion('first'), activityQuestion('second')],
      );
      await feed.retry();
      expect(repository.calls.last.cursor, 'cursor');
      expect(feed.items.map((q) => q.id), ['first', 'second']);
      expect(feed.nextCursor, isNull);
    },
  );

  test(
    'refresh preserves loaded page depth and commits only a complete successful snapshot',
    () async {
      repository.response = (_, _, cursor) async => ActivityPageData(
        items: [activityQuestion(cursor == null ? 'first' : 'second')],
        nextCursor: cursor == null ? 'cursor' : null,
      );
      final feed = makeFeed();
      await feed.refresh();
      await feed.loadMore();
      repository.response = (_, _, cursor) async {
        if (cursor != null) throw const ApiException('offline');
        return ActivityPageData(
          items: [activityQuestion('replacement')],
          nextCursor: 'cursor',
        );
      };
      await feed.refresh();
      expect(feed.items.map((q) => q.id), ['first', 'second']);
      expect(feed.error, isNotNull);
      repository.response = (_, _, cursor) async => ActivityPageData(
        items: [activityQuestion(cursor == null ? 'replacement' : 'older')],
        nextCursor: cursor == null ? 'cursor' : null,
      );
      await feed.retry();
      expect(feed.items.map((q) => q.id), ['replacement', 'older']);
    },
  );

  test(
    'changing view ignores the late previous request and clears old rows',
    () async {
      final active = Completer<ActivityPageData>();
      repository.response = (_, view, _) => view == ActivityView.active
          ? active.future
          : Future.value(
              ActivityPageData(
                items: [activityQuestion('history', status: 'accepted')],
              ),
            );
      final feed = makeFeed();
      await Future<void>.delayed(Duration.zero);
      await feed.selectView(ActivityView.history);
      active.complete(
        ActivityPageData(items: [activityQuestion('late-active')]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(feed.view, ActivityView.history);
      expect(feed.items.map((q) => q.id), ['history']);
    },
  );

  test(
    'account change clears rows immediately and ignores old in-flight pages',
    () async {
      repository.response = (_, _, _) async => ActivityPageData(
        items: [activityQuestion('private')],
        nextCursor: 'cursor',
      );
      final feed = makeFeed();
      await feed.refresh();
      final old = Completer<ActivityPageData>();
      repository.response = (_, _, _) => old.future;
      final pending = feed.loadMore();
      await Future<void>.delayed(Duration.zero);
      repository.response = (_, _, _) async => ActivityPageData(
        items: [activityQuestion('new-account', owner: 'another')],
      );
      auth.change(
        const AppUser(
          id: 'another',
          email: 'other@example.test',
          name: '다른 여행자',
          pointBalance: 1000,
          isAdmin: false,
        ),
      );
      expect(feed.items, isEmpty);
      await feed.refresh();
      old.complete(ActivityPageData(items: [activityQuestion('late-private')]));
      await pending;
      expect(feed.items.map((q) => q.id), ['new-account']);
      auth.change(null);
      expect(feed.items, isEmpty);
      expect(feed.nextCursor, isNull);
    },
  );

  for (final status in [401, 403, 404]) {
    test('authorization $status clears loaded summaries', () async {
      repository.response = (_, _, _) async => ActivityPageData(
        items: [activityQuestion('private')],
        nextCursor: 'cursor',
      );
      final feed = makeFeed();
      await feed.refresh();
      repository.response = (_, _, _) async =>
          throw ApiException('denied', status: status);
      await feed.refresh();
      expect(feed.items, isEmpty);
      expect(feed.nextCursor, isNull);
      expect(feed.hasLoaded, isFalse);
    });
  }

  test(
    'invalid cursor retry refreshes the first page instead of repeating invalid paging',
    () async {
      repository.response = (_, _, _) async => ActivityPageData(
        items: [activityQuestion('first')],
        nextCursor: 'bad',
      );
      final feed = makeFeed();
      await feed.refresh();
      repository.response = (_, _, _) async => throw const ApiException(
        'invalid',
        code: 'INVALID_ACTIVITY_CURSOR',
        status: 400,
      );
      await feed.loadMore();
      repository.response = (_, _, _) async =>
          const ActivityPageData(items: []);
      await feed.retry();
      expect(repository.calls.last.cursor, isNull);
    },
  );
}
