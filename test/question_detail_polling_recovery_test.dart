import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/helper_application/helper_repository.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/features/questions/question_detail_page.dart';
import 'package:local_qa_concierge/features/questions/question_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';

const _traveler = AppUser(
  id: 'traveler',
  email: 'traveler@example.test',
  name: 'Traveler',
  pointBalance: 1000,
  isAdmin: false,
);
const _otherTraveler = AppUser(
  id: 'other-traveler',
  email: 'other-traveler@example.test',
  name: 'Other traveler',
  pointBalance: 1000,
  isAdmin: false,
);
const _questionTitle = '공항에서 숙소까지 이동';
const _draft = '도착 시간이 늦어져서 밤 11시에도 버스가 있는지 궁금해요';
const _retainedDraftNotice = '입력한 코멘트는 이 화면에 남아 있어요. 연결 후 다시 시도해주세요.';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class _SignedInAuth extends AuthRepository {
  _SignedInAuth(super.client);

  AppUser _user = _traveler;

  @override
  AppUser get currentUser => _user;

  void changeUser(AppUser user) {
    _user = user;
    notifyListeners();
  }
}

class _DetailHarness {
  late final ApiClient api;
  late final _SignedInAuth auth;
  late final ProviderContainer container;
  late final GoRouter router;
  bool offline = false;
  bool _disposed = false;
  int detailStatus = 200;
  int detailRequests = 0;
  final commentRequests = <http.Request>[];
  final _queuedReplies = <Completer<http.Response>>[];
  final _allReplies = <Completer<http.Response>>[];

  final composer = find.byType(TextField);
  final submit = find.widgetWithText(FilledButton, '남기기');

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    api =
        ApiClient(
            baseUrl: 'https://example.test/api',
            client: MockClient((request) async {
              if (request.method == 'POST') {
                expectSync(request.url.path, endsWith('/comments'));
                commentRequests.add(request);
                if (_queuedReplies.isNotEmpty) {
                  return _queuedReplies.removeAt(0).future;
                }
                return _json({'id': 'comment'}, 201);
              }
              expectSync(request.method, 'GET');
              expectSync(request.url.path, startsWith('/api/questions/'));
              detailRequests++;
              if (offline) throw http.ClientException('offline');
              if (detailStatus != 200) {
                return _json({
                  'error': {
                    'code': detailStatus == 403 ? 'FORBIDDEN' : 'NOT_FOUND',
                    'message': '이 질문에 접근할 수 없습니다.',
                  },
                }, detailStatus);
              }
              final questionId = request.url.pathSegments.last;
              return _json({
                'id': questionId,
                'user_id': api.userId,
                'country': 'Spain',
                'city': 'Madrid',
                'category': '교통',
                'urgency': '보통',
                'title': questionId == 'travel-question'
                    ? _questionTitle
                    : '다음 여행 질문',
                'body': '짐이 많아서 버스를 타고 싶어요',
                'reward_points': 100,
                'status': 'open',
                'created_at': '2026-10-02T00:00:00Z',
              });
            }),
          )
          ..token = 'synthetic-test-token'
          ..userId = _traveler.id;
    auth = _SignedInAuth(api);
    // Exercise the production question provider and 15-second poller. Disable
    // only automatic error retries so each controlled poll has one response.
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authRepositoryProvider.overrideWithValue(auth),
        authStateProvider.overrideWith((ref) => const Stream<AppUser?>.empty()),
        currentProfileProvider.overrideWith((ref) async => auth.currentUser),
        helperApplicationProvider.overrideWith((ref) async => null),
      ],
    );
    router = GoRouter(
      initialLocation: '/questions/travel-question',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('질문 목록')),
        ),
        GoRoute(
          path: '/questions/:id',
          builder: (_, state) =>
              QuestionDetailPage(questionId: state.pathParameters['id']!),
        ),
      ],
    );
    addTearDown(() => dispose(tester));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(detailRequests, 1);
  }

  Future<void> dispose(WidgetTester tester) async {
    if (_disposed) return;
    _disposed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    for (final reply in _allReplies) {
      if (!reply.isCompleted) reply.complete(_json({'id': 'comment'}, 201));
    }
    await tester.pump();
    container.dispose();
    router.dispose();
    auth.dispose();
    api.dispose();
    await tester.pump();
  }

  Future<void> typeDraft(WidgetTester tester, [String value = _draft]) async {
    await tester.ensureVisible(composer);
    await tester.enterText(composer, value);
  }

  String draftText(WidgetTester tester) =>
      tester.widget<TextField>(composer).controller!.text;

  Completer<http.Response> holdNextComment() {
    final reply = Completer<http.Response>();
    _queuedReplies.add(reply);
    _allReplies.add(reply);
    return reply;
  }

  Future<void> submitDraft(
    WidgetTester tester, {
    bool duplicateTap = false,
  }) async {
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    if (duplicateTap) await tester.tap(submit);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
  }

  Future<void> poll(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
  }

  Future<void> changeAccount(WidgetTester tester, AppUser user) async {
    api
      ..token = 'synthetic-token-${user.id}'
      ..userId = user.id;
    auth.changeUser(user);
    // Mirror the production router's session-scoped cache invalidation while
    // keeping the same mounted page to exercise its account-change guard.
    container.invalidate(questionProvider);
    container.invalidate(currentProfileProvider);
    await tester.pumpAndSettle();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'reopening detail rechecks visibility instead of using old content',
    (tester) async {
      final harness = _DetailHarness();
      await harness.mount(tester);
      expect(find.text(_questionTitle), findsOneWidget);
      harness.router.go('/home');
      await tester.pumpAndSettle();
      // Another participant blocks or hides the exchange while this page is away.
      harness.detailStatus = 404;
      harness.router.go('/questions/travel-question');
      await tester.pumpAndSettle();
      expect(harness.detailRequests, 2);
      expect(find.text(_questionTitle), findsNothing);
      expect(find.text('잠시 연결을 확인해주세요'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await harness.dispose(tester);
    },
  );

  testWidgets(
    'unsent comment survives a failed foreground poll and reconnection',
    (tester) async {
      final harness = _DetailHarness();
      await harness.mount(tester);
      await harness.typeDraft(tester);

      // No manual refresh, navigation, or submit: the timer alone reaches the
      // transient network error while the traveler is composing.
      harness.offline = true;
      await harness.poll(tester);
      expect(harness.detailRequests, 2);
      expect(find.text(_questionTitle), findsNothing);
      expect(harness.composer, findsNothing);
      expect(find.text('잠시 연결을 확인해주세요'), findsOneWidget);
      expect(find.text(_retainedDraftNotice), findsOneWidget);

      harness.offline = false;
      await harness.poll(tester);
      expect(harness.detailRequests, 3);
      expect(find.text(_questionTitle), findsOneWidget);
      expect(harness.draftText(tester), _draft);
      expect(tester.takeException(), isNull);
      await harness.dispose(tester);
    },
  );

  for (final status in [403, 404]) {
    testWidgets(
      'HTTP $status hides question content and clears the unsent comment',
      (tester) async {
        final harness = _DetailHarness();
        await harness.mount(tester);
        await harness.typeDraft(tester);
        harness.detailStatus = status;
        await harness.poll(tester);
        expect(find.text(_questionTitle), findsNothing);
        expect(find.text(_draft), findsNothing);
        expect(harness.composer, findsNothing);
        expect(find.text('잠시 연결을 확인해주세요'), findsOneWidget);
        expect(find.text(_retainedDraftNotice), findsNothing);

        harness.detailStatus = 200;
        await harness.poll(tester);
        expect(find.text(_questionTitle), findsOneWidget);
        expect(harness.draftText(tester), isEmpty);
        expect(harness.commentRequests, isEmpty);
        expect(tester.takeException(), isNull);
        await harness.dispose(tester);
      },
    );
  }

  for (final changeAccount in [false, true]) {
    final scope = changeAccount ? 'account' : 'question';
    testWidgets(
      '$scope change isolates a new draft from the old comment acknowledgement',
      (tester) async {
        final harness = _DetailHarness();
        await harness.mount(tester);
        final originalPageState = tester.state(find.byType(QuestionDetailPage));
        await harness.typeDraft(tester);
        final oldReply = harness.holdNextComment();
        await harness.submitDraft(tester);
        expect(harness.commentRequests, hasLength(1));
        expect(
          harness.commentRequests.single.url.path,
          '/api/questions/travel-question/comments',
        );
        expect(jsonDecode(harness.commentRequests.single.body)['body'], _draft);

        if (changeAccount) {
          await harness.changeAccount(tester, _otherTraveler);
        } else {
          harness.router.go('/questions/other-question');
          await tester.pumpAndSettle();
          expect(find.text('다음 여행 질문'), findsOneWidget);
        }
        // Exercise state reuse, not a fresh route that trivially has no draft.
        expect(
          tester.state(find.byType(QuestionDetailPage)),
          same(originalPageState),
        );
        expect(harness.draftText(tester), isEmpty);
        expect(tester.widget<TextField>(harness.composer).enabled, isTrue);
        const newDraft = '새 화면에서 작성하는 다른 코멘트';
        await harness.typeDraft(tester, newDraft);

        oldReply.complete(_json({'id': 'old-comment'}, 201));
        await tester.pumpAndSettle();
        expect(harness.draftText(tester), newDraft);
        expect(harness.commentRequests, hasLength(1));
        expect(find.text('코멘트를 남겼습니다.'), findsNothing);
        expect(find.text('로그인 정보가 변경되었습니다. 다시 시도해주세요.'), findsNothing);
        expect(tester.takeException(), isNull);
        await harness.dispose(tester);
      },
    );
  }

  testWidgets(
    'one pending comment clears on acknowledgement while a poll error hides it',
    (tester) async {
      final harness = _DetailHarness();
      await harness.mount(tester);
      await harness.typeDraft(tester);
      // Start near the next poll so the acknowledgement still arrives within
      // the real transport's 12-second timeout, with no timeout override.
      await tester.pump(const Duration(seconds: 14));
      final reply = harness.holdNextComment();
      await harness.submitDraft(tester, duplicateTap: true);
      expect(harness.commentRequests, hasLength(1));
      expect(tester.widget<TextField>(harness.composer).enabled, isFalse);
      expect(tester.widget<FilledButton>(harness.submit).onPressed, isNull);

      harness.offline = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text(_questionTitle), findsNothing);
      expect(harness.composer, findsNothing);
      expect(find.text('잠시 연결을 확인해주세요'), findsOneWidget);
      expect(harness.commentRequests, hasLength(1));

      reply.complete(_json({'id': 'posted-comment'}, 201));
      await tester.pumpAndSettle();
      expect(find.text('코멘트를 남겼습니다.'), findsOneWidget);
      expect(harness.composer, findsNothing);
      expect(find.text(_retainedDraftNotice), findsNothing);

      harness.offline = false;
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(harness.draftText(tester), isEmpty);
      expect(tester.widget<TextField>(harness.composer).enabled, isTrue);
      expect(harness.commentRequests, hasLength(1));
      expect(tester.takeException(), isNull);
      await harness.dispose(tester);
    },
  );
}
