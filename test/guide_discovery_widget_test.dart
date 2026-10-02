import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/guide_discovery/guide_discovery_feed.dart';
import 'package:local_qa_concierge/features/guide_discovery/guide_discovery_repository.dart';
import 'package:local_qa_concierge/features/helper_application/helper_home_page.dart';
import 'package:local_qa_concierge/features/helper_application/helper_repository.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/features/questions/question_realtime.dart';
import 'package:local_qa_concierge/features/questions/question_repository.dart';
import 'package:local_qa_concierge/shared/models/guide_summary.dart';
import 'package:local_qa_concierge/shared/models/helper_application.dart';

import 'guide_discovery_feed_test.dart'
    show
        DiscoveryTestAuth,
        DiscoveryTestRepository,
        discoveryQuestion,
        discoveryUser;

void main() {
  late ApiClient api;
  late DiscoveryTestAuth auth;
  late DiscoveryTestRepository repository;
  late String approval;
  late int detailReads;
  setUp(() {
    api = ApiClient(baseUrl: 'https://example.test/api');
    auth = DiscoveryTestAuth(api);
    repository = DiscoveryTestRepository(api);
    approval = 'approved';
    detailReads = 0;
  });
  tearDown(() {
    auth.dispose();
    api.dispose();
  });

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    double scale = 1,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: '/helper/home',
      routes: [
        GoRoute(
          path: '/helper/home',
          builder: (_, _) => const HelperHomePage(),
        ),
        GoRoute(
          path: '/questions/:id',
          builder: (context, state) => Consumer(
            builder: (context, ref, _) {
              final detail = ref.watch(
                questionProvider(state.pathParameters['id']!),
              );
              return Scaffold(
                body: detail.when(
                  data: (question) => Column(
                    children: [
                      Text('새 상세 ${question.id}'),
                      TextButton(
                        onPressed: () => context.pop(),
                        child: const Text('목록으로 돌아가기'),
                      ),
                    ],
                  ),
                  loading: () => const Text('상세 확인 중'),
                  error: (_, _) => const Text('상세 오류'),
                ),
              );
            },
          ),
        ),
        GoRoute(
          path: '/activity/guide',
          builder: (_, _) => const Scaffold(body: Text('개인 맡은 질문 화면')),
        ),
        GoRoute(
          path: '/helper/waiting',
          builder: (_, _) => const Scaffold(body: Text('신청 결과 화면')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          guideDiscoveryRepositoryProvider.overrideWithValue(repository),
          currentProfileProvider.overrideWith((_) async => discoveryUser),
          questionRealtimeProvider.overrideWith((_) {}),
          guideSummaryProvider.overrideWith(
            (_) async => const GuideSummary(
              acceptedAnswerCount: 0,
              earnedMockPoints: 0,
              pendingMockPoints: 0,
              applicationStatus: 'approved',
              activityRegions: [],
            ),
          ),
          helperApplicationProvider.overrideWith(
            (_) async => HelperApplication(
              id: 'application',
              userId: 'guide',
              status: approval,
              languages: const ['ko'],
              introduction: '',
              experienceDescription: '',
            ),
          ),
          questionProvider.overrideWith((_, id) async {
            detailReads++;
            return discoveryQuestion(id);
          }),
          helperOpenQuestionsProvider.overrideWith(
            (_) => throw StateError('Legacy feed must never be read'),
          ),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(),
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    addTearDown(() async => tester.pumpWidget(const SizedBox()));
    return ProviderScope.containerOf(
      tester.element(find.byType(HelperHomePage)),
    );
  }

  testWidgets('loading, error, retry and genuine empty states are distinct', (
    tester,
  ) async {
    final pending = Completer<GuideDiscoveryPageData>();
    repository.response = (_) => pending.future;
    await mount(tester);
    expect(find.text('지역의 질문을 불러오고 있어요'), findsOneWidget);
    expect(find.text('지금 수락 가능한 질문이 없어요'), findsNothing);
    pending.completeError(const ApiException('offline', code: 'connection'));
    await tester.pumpAndSettle();
    expect(find.text('질문을 불러오지 못했어요'), findsOneWidget);
    expect(find.text('지금 수락 가능한 질문이 없어요'), findsNothing);
    repository.response = (_) async => const GuideDiscoveryPageData(items: []);
    await tester.tap(find.text('질문 다시 불러오기'));
    await tester.pumpAndSettle();
    expect(find.text('지금 수락 가능한 질문이 없어요'), findsOneWidget);
    expect(find.text('질문을 불러오지 못했어요'), findsNothing);
  });

  testWidgets(
    'explicit more reaches older rows, failed page retains labelled data, retry appends once',
    (tester) async {
      repository.response = (_) async => GuideDiscoveryPageData(
        items: [for (var i = 0; i < 20; i++) discoveryQuestion('$i')],
        nextCursor: 'older',
      );
      final container = await mount(tester);
      expect(repository.calls, [null]);
      expect(detailReads, 0);
      expect(find.byType(Image), findsNothing);
      repository.response = (_) async =>
          throw const ApiException('offline', code: 'timeout');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('discovery-load-more')),
        500,
        maxScrolls: 40,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('discovery-load-more')));
      await tester.pumpAndSettle();
      final feed = container.read(guideDiscoveryFeedProvider);
      expect(feed.items.length, 20);
      await tester.scrollUntilVisible(
        find.text('질문 다시 불러오기'),
        -500,
        maxScrolls: 40,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('이전에 불러온 내용'), findsOneWidget);
      repository.response = (_) async => GuideDiscoveryPageData(
        items: [discoveryQuestion('19'), discoveryQuestion('20')],
      );
      await tester.tap(find.text('질문 다시 불러오기'));
      await tester.pumpAndSettle();
      expect(repository.calls, [null, 'older', 'older']);
      expect(feed.items.length, 21);
      await tester.scrollUntilVisible(find.text('질문 20'), 500, maxScrolls: 40);
      expect(find.text('질문 20'), findsOneWidget);
      expect(find.byKey(const ValueKey('discovery-load-more')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid open taps fetch one fresh detail, one back refreshes eligibility and personal work stays separate',
    (tester) async {
      repository.response = (_) async =>
          GuideDiscoveryPageData(items: [discoveryQuestion('station')]);
      await mount(tester);
      expect(find.text('맡은 질문'), findsOneWidget);
      expect(find.text('1:1로 수락'), findsNothing);
      expect(find.text('질문 보상 · 가상 100P'), findsOneWidget);
      await tester.ensureVisible(find.text('질문 자세히 보기'));
      await tester.tap(find.text('질문 자세히 보기'));
      // No frame between taps: both can hit the previous button callback.
      await tester.tap(find.text('질문 자세히 보기'));
      await tester.pumpAndSettle();
      expect(find.text('새 상세 station'), findsOneWidget);
      expect(detailReads, 1);
      repository.response = (_) async =>
          const GuideDiscoveryPageData(items: []);
      await tester.tap(find.text('목록으로 돌아가기'));
      await tester.pumpAndSettle();
      expect(repository.calls.length, 2);
      expect(find.text('지금 수락 가능한 질문이 없어요'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('맡은 질문'), -200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('맡은 질문'));
      await tester.pumpAndSettle();
      expect(find.text('개인 맡은 질문 화면'), findsOneWidget);
    },
  );

  testWidgets(
    'foreground refresh preserves feed identity and approval revoke removes rows',
    (tester) async {
      repository.response = (_) async =>
          GuideDiscoveryPageData(items: [discoveryQuestion('old-region')]);
      final container = await mount(tester);
      final feed = container.read(guideDiscoveryFeedProvider);
      repository.response = (_) async =>
          GuideDiscoveryPageData(items: [discoveryQuestion('current-region')]);
      container.invalidate(guideDiscoveryRefreshProvider);
      await tester.pumpAndSettle();
      expect(container.read(guideDiscoveryFeedProvider), same(feed));
      expect(find.text('질문 current-region'), findsOneWidget);
      expect(find.text('질문 old-region'), findsNothing);
      approval = 'rejected';
      container.invalidate(helperApplicationProvider);
      await tester.pumpAndSettle();
      expect(find.text('질문 current-region'), findsNothing);
      expect(find.text('현재 답변에 참여할 수 없어요'), findsOneWidget);
      expect(feed.items, isEmpty);
    },
  );

  testWidgets(
    'loaded pages survive scrolling beyond discovery into guide activity',
    (tester) async {
      repository.response = (cursor) async => GuideDiscoveryPageData(
        items: [discoveryQuestion(cursor == null ? 'first' : 'older')],
        nextCursor: cursor == null ? 'next' : null,
      );
      final container = await mount(
        tester,
        scale: 2,
        size: const Size(320, 640),
      );
      final feed = container.read(guideDiscoveryFeedProvider);
      await feed.loadMore();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('여행자가 채택하면 도움 기록과 가상 포인트가 쌓여요.'),
        400,
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('discovery-question-first')),
        findsNothing,
      );
      expect(container.read(guideDiscoveryFeedProvider), same(feed));
      await tester.scrollUntilVisible(
        find.text('질문 older'),
        -400,
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();
      expect(find.text('질문 older'), findsOneWidget);
      expect(repository.calls, [null, 'next']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final code in [
    'HELPER_NOT_APPROVED',
    'ACCOUNT_SUSPENDED',
    'UNAUTHENTICATED',
  ]) {
    testWidgets(
      '$code never labels unauthorized rows as saved data or empty work',
      (tester) async {
        repository.response = (_) async =>
            GuideDiscoveryPageData(items: [discoveryQuestion('private')]);
        final container = await mount(tester);
        repository.response = (_) async => throw ApiException(
          'denied',
          code: code,
          status: code == 'UNAUTHENTICATED' ? 401 : 403,
        );
        await container.read(guideDiscoveryFeedProvider).refresh();
        await tester.pumpAndSettle();
        expect(find.text('질문 private'), findsNothing);
        expect(find.textContaining('이전에 불러온 내용'), findsNothing);
        expect(find.text('지금 수락 가능한 질문이 없어요'), findsNothing);
        expect(find.text('질문을 불러오지 못했어요'), findsOneWidget);
      },
    );
  }

  testWidgets(
    '320px double text keeps title, long region and explicit actions readable without overflow',
    (tester) async {
      repository.response = (_) async => GuideDiscoveryPageData(
        items: [discoveryQuestion('말라가 기차역에서 늦은 밤 숙소까지 가는 버스를 어디에서 타야 하나요')],
        nextCursor: 'older',
      );
      await mount(tester, scale: 2, size: const Size(320, 640));
      await tester.scrollUntilVisible(
        find.text('질문 자세히 보기'),
        200,
        maxScrolls: 30,
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('말라가 기차역'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('discovery-load-more')),
        200,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('더 보기'), findsOneWidget);
    },
  );
}
