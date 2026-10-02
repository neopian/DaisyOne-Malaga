import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/activity/activity_page.dart';
import 'package:local_qa_concierge/features/activity/activity_repository.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/features/questions/question_realtime.dart';

import 'activity_feed_test.dart'
    show
        ActivityTestAuth,
        ActivityTestRepository,
        activityQuestion,
        activityUser;

void main() {
  late ApiClient api;
  late ActivityTestAuth auth;
  late ActivityTestRepository repository;
  setUp(() {
    api = ApiClient(baseUrl: 'https://example.test/api');
    auth = ActivityTestAuth(api);
    repository = ActivityTestRepository(api);
  });
  tearDown(() {
    auth.dispose();
    api.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    ActivityRole role = ActivityRole.traveler,
    double scale = 1,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: '/activity/${role.name}',
      routes: [
        GoRoute(
          path: '/activity/:role',
          builder: (_, state) => ActivityPage(
            role: ActivityRole.values.byName(state.pathParameters['role']!),
          ),
        ),
        GoRoute(
          path: '/questions/:id',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => context.pop(),
              child: Text('돌아가기 ${state.pathParameters['id']}'),
            ),
          ),
        ),
        GoRoute(
          path: '/helper/home',
          builder: (_, _) => const Scaffold(body: Text('가이드 홈')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activityRepositoryProvider.overrideWithValue(repository),
          authRepositoryProvider.overrideWithValue(auth),
          currentProfileProvider.overrideWith((_) async => activityUser),
          questionRealtimeProvider.overrideWith((_) {}),
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
  }

  testWidgets('loading, failure, retry and empty states remain distinct', (
    tester,
  ) async {
    final pending = Completer<ActivityPageData>();
    repository.response = (_, _, _) => pending.future;
    await mount(tester);
    expect(find.text('질문 목록을 확인하고 있어요'), findsOneWidget);
    expect(find.text('진행 중인 내 질문이 없어요'), findsNothing);
    pending.completeError(const ApiException('offline'));
    await tester.pumpAndSettle();
    expect(find.text('질문 목록을 확인하지 못했어요'), findsOneWidget);
    expect(find.text('진행 중인 내 질문이 없어요'), findsNothing);
    repository.response = (_, _, _) async => const ActivityPageData(items: []);
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(find.text('진행 중인 내 질문이 없어요'), findsOneWidget);
    expect(find.text('질문 목록을 확인하지 못했어요'), findsNothing);
  });

  testWidgets(
    'traveler can review answer and return to a refreshed map-independent list',
    (tester) async {
      repository.response = (_, _, _) async => ActivityPageData(
        items: [activityQuestion('paris', status: 'answered')],
      );
      await mount(tester);
      expect(find.text('답변 도착'), findsOneWidget);
      expect(find.text('답변 검토'), findsOneWidget);
      expect(find.text('질문 보상 · 가상 100P'), findsOneWidget);
      await tester.tap(find.text('답변 검토'));
      await tester.pumpAndSettle();
      expect(find.text('돌아가기 paris'), findsOneWidget);
      repository.response = (_, _, _) async =>
          const ActivityPageData(items: []);
      await tester.tap(find.text('돌아가기 paris'));
      await tester.pumpAndSettle();
      expect(find.text('진행 중인 내 질문이 없어요'), findsOneWidget);
      expect(repository.calls.length, greaterThan(1));
    },
  );

  testWidgets(
    'paging offline retains rows with explicit old-data notice and retry',
    (tester) async {
      repository.response = (_, _, _) async => ActivityPageData(
        items: [activityQuestion('saved')],
        nextCursor: 'next',
      );
      await mount(tester);
      repository.response = (_, _, _) async =>
          throw const ApiException('offline');
      await tester.ensureVisible(find.text('더 보기'));
      await tester.tap(find.text('더 보기'));
      await tester.pumpAndSettle();
      expect(find.text('질문 saved'), findsOneWidget);
      expect(find.textContaining('이전에 불러온 내용'), findsOneWidget);
      repository.response = (_, _, _) async =>
          ActivityPageData(items: [activityQuestion('older')]);
      await tester.ensureVisible(find.text('다시 시도'));
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(repository.calls.last.cursor, 'next');
      await tester.scrollUntilVisible(find.text('질문 older'), 200);
      expect(find.text('질문 older'), findsOneWidget);
    },
  );

  testWidgets(
    'history and guide next steps stay usable on 320px phone at double text',
    (tester) async {
      repository.response = (_, view, _) async => ActivityPageData(
        items: [
          activityQuestion(
            '파리 공항에서 숙소까지 늦은 밤에 이동하는 방법을 확인해주세요',
            status: view == ActivityView.active ? 'assigned' : 'accepted',
          ),
        ],
      );
      await mount(
        tester,
        role: ActivityRole.guide,
        scale: 2,
        size: const Size(320, 640),
      );
      expect(find.text('맡은 질문'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('답변 이어가기'), 200);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('activity-view-history')),
        -200,
      );
      await tester.tap(find.byKey(const ValueKey('activity-view-history')));
      await tester.pumpAndSettle();
      expect(repository.calls.last.view, ActivityView.history);
      await tester.scrollUntilVisible(find.text('완료한 답변 보기'), 200);
      expect(find.text('완료한 답변 보기'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
