import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/guide_discovery/guide_discovery_feed.dart';
import 'package:local_qa_concierge/features/guide_discovery/guide_discovery_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:local_qa_concierge/shared/models/question.dart';

const discoveryUser = AppUser(
  id: 'guide',
  email: 'guide@example.test',
  name: '가이드',
  pointBalance: 1000,
  isAdmin: false,
);

class DiscoveryTestAuth extends AuthRepository {
  DiscoveryTestAuth(super.client);
  AppUser? user = discoveryUser;
  @override
  AppUser? get currentUser => user;
  void change(AppUser? next) {
    user = next;
    notifyListeners();
  }
}

Question discoveryQuestion(
  String id, {
  String owner = 'traveler',
  String status = 'open',
}) => Question.fromMap({
  'id': id,
  'user_id': owner,
  'title': '질문 $id',
  'status': status,
  'country': 'Spain',
  'city': 'Malaga',
  'region_name': 'Centro',
  'category': '교통',
  'reward_points': 100,
  'created_at': '2026-10-02T00:00:00Z',
});

class DiscoveryTestRepository extends GuideDiscoveryRepository {
  DiscoveryTestRepository(super.client);
  final calls = <String?>[];
  Future<GuideDiscoveryPageData> Function(String?) response = (_) async =>
      const GuideDiscoveryPageData(items: []);
  @override
  Future<GuideDiscoveryPageData> fetchPage({String? cursor}) {
    calls.add(cursor);
    return response(cursor);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'compact API uses only opaque cursor and never requests detail or media',
    () async {
      final requests = <Uri>[];
      final client = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 'question',
                  'user_id': 'traveler',
                  'title': 'Summary',
                  'body': 'must not be used',
                  'question_images': [
                    {'image_url': '/image'},
                  ],
                  'answers': [{}],
                  'question_comments': [{}],
                  'assigned_helper': {},
                  'accepted_answer_id': 'answer',
                  'latitude': 36,
                  'longitude': -4,
                },
              ],
              'next_cursor': 'next',
            }),
            200,
          );
        }),
      )..token = 'session';
      addTearDown(client.dispose);
      final page = await GuideDiscoveryRepository(
        client,
      ).fetchPage(cursor: 'opaque+/=&value');
      expect(requests.single.path, '/api/guide/discovery');
      expect(requests.single.queryParameters, {'cursor': 'opaque+/=&value'});
      expect(page.nextCursor, 'next');
      final item = page.items.single;
      expect(item.title, 'Summary');
      expect(item.body, isEmpty);
      expect(item.images, isEmpty);
      expect(item.answers, isEmpty);
      expect(item.comments, isEmpty);
      expect(item.assignedHelper, isNull);
      expect(item.acceptedAnswerId, isNull);
      expect(item.latitude, isNull);
      expect(item.longitude, isNull);
    },
  );

  for (final body in [
    null,
    [],
    42,
    {'items': null},
    {
      'items': [null],
    },
    {
      'items': [
        {'id': 'missing-owner'},
      ],
    },
    {'items': [], 'next_cursor': ''},
    {'items': [], 'next_cursor': 'cursor'},
    {
      'items': [
        {'id': 'q', 'user_id': 'u', 'title': 3},
      ],
    },
    {
      'items': List.filled(21, {'id': 'q', 'user_id': 'u'}),
    },
  ]) {
    test('malformed discovery page is an error: $body', () async {
      final client = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((_) async => http.Response(jsonEncode(body), 200)),
      )..token = 'session';
      addTearDown(client.dispose);
      await expectLater(
        GuideDiscoveryRepository(client).fetchPage(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'INVALID_DISCOVERY_RESPONSE',
          ),
        ),
      );
    });
  }

  for (final code in [
    'HELPER_NOT_APPROVED',
    'ACCOUNT_SUSPENDED',
    'UNAUTHENTICATED',
    'INVALID_DISCOVERY_QUERY',
    'INVALID_DISCOVERY_CURSOR',
  ]) {
    test('repository preserves authority/query error $code', () async {
      final client = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'code': code},
            }),
            code == 'UNAUTHENTICATED'
                ? 401
                : code.startsWith('INVALID')
                ? 400
                : 403,
          ),
        ),
      )..token = 'session';
      addTearDown(client.dispose);
      await expectLater(
        GuideDiscoveryRepository(client).fetchPage(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', code)),
      );
    });
  }

  late ApiClient client;
  late DiscoveryTestAuth auth;
  late DiscoveryTestRepository repository;
  setUp(() {
    client = ApiClient(baseUrl: 'https://example.test/api');
    auth = DiscoveryTestAuth(client);
    repository = DiscoveryTestRepository(client);
  });
  tearDown(() {
    auth.dispose();
    client.dispose();
  });
  GuideDiscoveryFeed makeFeed({bool approved = true}) {
    final feed = GuideDiscoveryFeed(
      repository: repository,
      auth: auth,
      approved: approved,
    );
    addTearDown(feed.dispose);
    return feed;
  }

  test(
    'explicit 20-row pages reach work beyond old 200 limit without a cap',
    () async {
      repository.response = (cursor) async {
        final offset = int.parse(cursor ?? '0');
        final end = offset + 20 > 221 ? 221 : offset + 20;
        return GuideDiscoveryPageData(
          items: [for (var i = offset; i < end; i++) discoveryQuestion('$i')],
          nextCursor: end < 221 ? '$end' : null,
        );
      };
      final feed = makeFeed();
      await feed.refresh();
      expect(feed.items.length, 20);
      expect(repository.calls, [null]);
      while (feed.nextCursor != null) {
        await feed.loadMore();
      }
      expect(feed.items.length, 221);
      expect(feed.items.last.id, '220');
      expect(repository.calls.length, 12);
      await feed.loadMore();
      expect(repository.calls.length, 12);
    },
  );

  test(
    'repeated requests coalesce, overlapping IDs merge, and retry retains page cursor',
    () async {
      repository.response = (_) async => GuideDiscoveryPageData(
        items: [discoveryQuestion('first')],
        nextCursor: 'cursor',
      );
      final feed = makeFeed();
      await feed.refresh();
      final pending = Completer<GuideDiscoveryPageData>();
      repository.response = (_) => pending.future;
      final one = feed.loadMore();
      final two = feed.loadMore();
      expect(identical(one, two), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(repository.calls, [null, 'cursor']);
      pending.completeError(const ApiException('offline', code: 'connection'));
      await one;
      expect(feed.items.single.id, 'first');
      expect(feed.nextCursor, 'cursor');
      repository.response = (_) async => GuideDiscoveryPageData(
        items: [discoveryQuestion('first'), discoveryQuestion('older')],
      );
      await feed.retry();
      expect(repository.calls.last, 'cursor');
      expect(feed.items.map((q) => q.id), ['first', 'older']);
      expect(feed.error, isNull);
    },
  );

  test(
    'refresh revalidates the loaded window atomically and region changes remove old rows',
    () async {
      repository.response = (cursor) async => GuideDiscoveryPageData(
        items: [discoveryQuestion(cursor == null ? 'first' : 'older')],
        nextCursor: cursor == null ? 'next' : null,
      );
      final feed = makeFeed();
      await feed.refresh();
      await feed.loadMore();
      repository.response = (cursor) async {
        if (cursor != null) throw const ApiException('offline', status: 503);
        return GuideDiscoveryPageData(
          items: [discoveryQuestion('changed')],
          nextCursor: 'new-next',
        );
      };
      await feed.refresh();
      expect(feed.items.map((q) => q.id), ['first', 'older']);
      expect(repository.calls.sublist(2), [null, 'new-next']);
      repository.response = (_) async =>
          GuideDiscoveryPageData(items: [discoveryQuestion('new-region')]);
      await feed.retry();
      expect(repository.calls.last, isNull);
      expect(feed.items.single.id, 'new-region');
      expect(feed.nextCursor, isNull);
    },
  );

  for (final failure in [
    const ApiException('revoked', code: 'HELPER_NOT_APPROVED', status: 403),
    const ApiException('suspended', code: 'ACCOUNT_SUSPENDED', status: 403),
    const ApiException('expired', code: 'UNAUTHENTICATED', status: 401),
    const ApiException('region', code: 'REGION_MISMATCH', status: 403),
    const ApiException('changed', code: 'session_changed'),
    const ApiException(
      'bad query',
      code: 'INVALID_DISCOVERY_QUERY',
      status: 400,
    ),
    const ApiException('bad response', code: 'INVALID_DISCOVERY_RESPONSE'),
  ]) {
    test(
      '${failure.code} clears previous rows, cursors and loaded window',
      () async {
        repository.response = (_) async => GuideDiscoveryPageData(
          items: [discoveryQuestion('old')],
          nextCursor: 'cursor',
        );
        final feed = makeFeed();
        await feed.refresh();
        repository.response = (_) async => throw failure;
        await feed.loadMore();
        expect(feed.items, isEmpty);
        expect(feed.nextCursor, isNull);
        expect(feed.hasLoaded, isFalse);
        expect(feed.error, same(failure));
      },
    );
  }

  test(
    'invalid cursor clears and retry restarts without reusing stale cursor',
    () async {
      repository.response = (_) async => GuideDiscoveryPageData(
        items: [discoveryQuestion('old')],
        nextCursor: 'stale',
      );
      final feed = makeFeed();
      await feed.refresh();
      repository.response = (_) async => throw const ApiException(
        'stale',
        code: 'INVALID_DISCOVERY_CURSOR',
        status: 400,
      );
      await feed.loadMore();
      expect(feed.items, isEmpty);
      expect(feed.nextCursor, isNull);
      repository.response = (_) async =>
          GuideDiscoveryPageData(items: [discoveryQuestion('fresh')]);
      await feed.retry();
      expect(repository.calls.last, isNull);
      expect(feed.items.single.id, 'fresh');
    },
  );

  test('cursor cycles cannot repeat older pages indefinitely', () async {
    repository.response = (cursor) async => GuideDiscoveryPageData(
      items: [discoveryQuestion(cursor ?? 'first')],
      nextCursor: cursor == null
          ? 'a'
          : cursor == 'a'
          ? 'b'
          : 'a',
    );
    final feed = makeFeed();
    await feed.refresh();
    await feed.loadMore();
    await feed.loadMore();
    expect(feed.items, isEmpty);
    expect((feed.error as ApiException).code, 'INVALID_DISCOVERY_CURSOR');
  });

  test(
    'approval loss ignores pending success and blocks even an admin until approved',
    () async {
      auth.change(
        const AppUser(
          id: 'admin',
          email: '',
          name: '',
          pointBalance: 0,
          isAdmin: true,
        ),
      );
      final feed = makeFeed(approved: false);
      await feed.refresh();
      expect(repository.calls, isEmpty);
      final pending = Completer<GuideDiscoveryPageData>();
      repository.response = (_) => pending.future;
      feed.setApproved(true);
      final result = feed.refresh();
      await Future<void>.delayed(Duration.zero);
      feed.setApproved(false);
      pending.complete(
        GuideDiscoveryPageData(items: [discoveryQuestion('old')]),
      );
      await result;
      expect(feed.items, isEmpty);
      expect(feed.hasLoaded, isFalse);
      await feed.refresh();
      expect(repository.calls.length, 1);
    },
  );

  test(
    'account switch clears synchronously and requires the new account approval',
    () async {
      repository.response = (_) async =>
          GuideDiscoveryPageData(items: [discoveryQuestion('first')]);
      final feed = makeFeed();
      await feed.refresh();
      final pending = Completer<GuideDiscoveryPageData>();
      repository.response = (_) => pending.future;
      final oldRequest = feed.refresh();
      await Future<void>.delayed(Duration.zero);
      auth.change(
        const AppUser(
          id: 'other-guide',
          email: '',
          name: '',
          pointBalance: 0,
          isAdmin: false,
        ),
      );
      expect(feed.items, isEmpty);
      expect(feed.isLoading, isFalse);
      await feed.refresh();
      expect(repository.calls.length, 2);
      repository.response = (_) async =>
          GuideDiscoveryPageData(items: [discoveryQuestion('new')]);
      feed.setApproved(true);
      await feed.refresh();
      pending.complete(
        GuideDiscoveryPageData(items: [discoveryQuestion('old')]),
      );
      await oldRequest;
      expect(feed.items.single.id, 'new');
      auth.change(null);
      expect(feed.items, isEmpty);
      expect(feed.nextCursor, isNull);
    },
  );

  test('same-account suspension clears rows immediately', () async {
    repository.response = (_) async =>
        GuideDiscoveryPageData(items: [discoveryQuestion('first')]);
    final feed = makeFeed();
    await feed.refresh();
    auth.change(
      const AppUser(
        id: 'guide',
        email: '',
        name: '',
        pointBalance: 0,
        isAdmin: false,
        isSuspended: true,
      ),
    );
    expect(feed.items, isEmpty);
    await feed.refresh();
    expect(repository.calls.length, 1);
  });

  test(
    'detail return supersedes older poll response and discards non-open/own rows',
    () async {
      repository.response = (_) async =>
          GuideDiscoveryPageData(items: [discoveryQuestion('first')]);
      final feed = makeFeed();
      await feed.refresh();
      final pending = Completer<GuideDiscoveryPageData>();
      repository.response = (_) => pending.future;
      final oldRequest = feed.refresh();
      await Future<void>.delayed(Duration.zero);
      repository.response = (_) async => GuideDiscoveryPageData(
        items: [
          discoveryQuestion('eligible'),
          discoveryQuestion('own', owner: 'guide'),
          discoveryQuestion('claimed', status: 'assigned'),
        ],
      );
      await feed.refreshAfterDetail();
      pending.complete(
        GuideDiscoveryPageData(items: [discoveryQuestion('stale')]),
      );
      await oldRequest;
      expect(feed.items.map((q) => q.id), ['eligible']);
    },
  );
}
