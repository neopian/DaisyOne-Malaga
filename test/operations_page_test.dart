import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/app/router.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/admin/admin_home_page.dart';
import 'package:local_qa_concierge/features/admin/operations_page.dart';
import 'package:local_qa_concierge/features/admin/operations_repository.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';

import 'operations_test_support.dart';

void main() {
  test('operations deep link requires an active admin session', () {
    String? redirect(bool initialized, bool? admin, {bool suspended = false}) =>
        authRedirect(
          initialized: initialized,
          user: admin == null
              ? null
              : operationsUser(isAdmin: admin, isSuspended: suspended),
          location: '/admin/operations',
        );
    expect(redirect(false, null), '/');
    expect(redirect(true, null), '/auth');
    expect(redirect(true, false), '/home');
    expect(redirect(true, true, suspended: true), '/account');
    expect(redirect(true, true), isNull);
  });
  late ApiClient api;
  late OperationsTestAuth auth;
  late OperationsTestRepository repository;
  setUp(() {
    api = ApiClient(baseUrl: 'https://example.test/api');
    auth = OperationsTestAuth(api);
    repository = OperationsTestRepository(api);
  });
  tearDown(() {
    auth.dispose();
    api.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    double scale = 1,
    Size size = const Size(390, 844),
    bool home = false,
    bool failProfileFirst = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var profileCalls = 0;
    final router = GoRouter(
      initialLocation: home ? '/admin' : '/admin/operations',
      routes: [
        GoRoute(path: '/admin', builder: (_, _) => const AdminHomePage()),
        GoRoute(
          path: '/admin/operations',
          builder: (_, _) => const OperationsPage(),
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
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        retry: (_, _) => null,
        overrides: [
          operationsRepositoryProvider.overrideWithValue(repository),
          authRepositoryProvider.overrideWithValue(auth),
          currentProfileProvider.overrideWith((_) async {
            if (failProfileFirst && profileCalls++ == 0) {
              throw const ApiException('offline');
            }
            return operationsUser();
          }),
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

  Future<void> reveal(
    WidgetTester tester,
    Finder finder, {
    double delta = 250,
  }) async {
    await tester.scrollUntilVisible(finder, delta);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'loading, error, retry and empty have no fabricated zero counts',
    (tester) async {
      final pending = Completer<OperationsPageData>();
      repository.response = (_, _, _) => pending.future;
      await mount(tester);
      expect(find.text('건수 확인 중'), findsNWidgets(3));
      expect(find.text('0건'), findsNothing);
      pending.completeError(const ApiException('offline'));
      await tester.pumpAndSettle();
      expect(find.text('건수 확인 불가'), findsNWidgets(3));
      expect(find.text('0건'), findsNothing);
      repository.response = (_, _, _) async => const OperationsPageData(
        items: [],
        summary: OperationsSummary(
          openCount: 0,
          assignedCount: 8,
          answeredCount: 3,
        ),
      );
      await reveal(tester, find.text('다시 시도'));
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('선택한 지역에 답변자 대기 질문이 없습니다.'));
      expect(find.text('선택한 지역에 답변자 대기 질문이 없습니다.'), findsOneWidget);
      await reveal(tester, find.text('0건'), delta: -250);
      expect(find.text('0건'), findsOneWidget);
    },
  );

  testWidgets(
    'all operational flags and timestamps lead to existing detail and refresh on return',
    (tester) async {
      repository.response = (status, _, _) async => OperationsPageData(
        items: [
          operationsQuestion('restricted', status: status, restricted: true),
        ],
        summary: operationsSummary,
      );
      await mount(tester);
      await reveal(tester, find.text('질문 상세 확인'));
      for (final flag in [
        '질문 숨김',
        '여행자 이용 제한',
        '가이드 이용 제한',
        '가이드 승인 없음',
        '참여자 간 차단',
      ]) {
        expect(find.text('• $flag'), findsOneWidget);
      }
      expect(find.textContaining('등록 · 2026.09.28'), findsOneWidget);
      expect(find.textContaining('최근 변경 · 2026.10.02'), findsOneWidget);
      await tester.tap(find.text('질문 상세 확인'));
      await tester.pumpAndSettle();
      expect(find.text('돌아가기 restricted'), findsOneWidget);
      repository.response = (_, _, _) async =>
          const OperationsPageData(items: [], summary: operationsSummary);
      await tester.tap(find.text('돌아가기 restricted'));
      await tester.pumpAndSettle();
      expect(repository.calls, hasLength(2));
      expect(find.text('질문 restricted'), findsNothing);
    },
  );

  testWidgets(
    'city picker close and keyboard search preserve then change geographic scope',
    (tester) async {
      await mount(tester);
      final calls = repository.calls.length;
      await tester.tap(find.byKey(const ValueKey('operations-city-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(repository.calls, hasLength(calls));
      await tester.tap(find.byKey(const ValueKey('operations-city-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('travel-city-search')),
        'Paris',
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(repository.calls.last.city?.city, 'Paris');
      expect(find.text('프랑스 · 파리'), findsOneWidget);
      expect(repository.calls.last.cursor, isNull);
      await tester.tap(find.byKey(const ValueKey('operations-all-cities')));
      await tester.pumpAndSettle();
      expect(repository.calls.last.city, isNull);
      expect(find.text('전체 지역 · 도시 선택'), findsOneWidget);
    },
  );

  testWidgets(
    'paging interruption keeps previous same-scope rows with truthful notice',
    (tester) async {
      repository.response = (_, _, _) async => OperationsPageData(
        items: [operationsQuestion('saved')],
        nextCursor: 'next',
        summary: operationsSummary,
      );
      await mount(tester);
      repository.response = (_, _, _) async =>
          throw const ApiException('offline');
      await reveal(tester, find.text('더 보기'));
      await tester.tap(find.text('더 보기'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('다시 시도'), delta: -250);
      expect(find.textContaining('이전에 불러온 내용'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('operations-question-saved')),
        findsOneWidget,
      );
      repository.response = (_, _, _) async => OperationsPageData(
        items: [operationsQuestion('older')],
        summary: operationsSummary,
      );
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(repository.calls.last.cursor, 'next');
      await reveal(tester, find.text('질문 older'));
      expect(find.text('질문 older'), findsOneWidget);
    },
  );

  testWidgets(
    'role loss clears private UI before any pending request completes',
    (tester) async {
      repository.response = (_, _, _) async => OperationsPageData(
        items: [operationsQuestion('private')],
        summary: operationsSummary,
      );
      await mount(tester);
      await reveal(tester, find.text('질문 private'));
      final pending = Completer<OperationsPageData>();
      repository.response = (_, _, _) => pending.future;
      await tester.tap(find.byTooltip('현황 새로고침'));
      await tester.pump();
      auth.change(operationsUser(isAdmin: false));
      await tester.pump();
      expect(find.text('질문 private'), findsNothing);
      expect(find.text('42건'), findsNothing);
      pending.complete(
        OperationsPageData(
          items: [operationsQuestion('late')],
          summary: operationsSummary,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('질문 late'), findsNothing);
      expect(find.text('42건'), findsNothing);
    },
  );

  testWidgets(
    '320px and doubled text keep filters and long restricted question usable',
    (tester) async {
      repository.response = (status, _, _) async => OperationsPageData(
        items: [
          operationsQuestion(
            '파리 공항에서 늦은 밤에 숙소까지 이동하는 방법을 확인해주세요',
            status: status,
            restricted: true,
          ),
        ],
        summary: operationsSummary,
      );
      await mount(tester, size: const Size(320, 640), scale: 2);
      await reveal(
        tester,
        find.byKey(const ValueKey('operations-status-answered')),
      );
      await tester.tap(
        find.byKey(const ValueKey('operations-status-answered')),
      );
      await tester.pumpAndSettle();
      expect(repository.calls.last.status, OperationsStatus.answered);
      await reveal(tester, find.text('질문 상세 확인'));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('질문 상세 확인'));
      await tester.pumpAndSettle();
      expect(find.textContaining('돌아가기 파리'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'admin home recovers a profile failure and exposes operations navigation',
    (tester) async {
      await mount(tester, home: true, failProfileFirst: true);
      expect(find.text('다시 시도'), findsOneWidget);
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('응답 대기 현황'));
      await tester.pumpAndSettle();
      expect(find.text('진행 상황 확인용이며 자동 배정·환불은 하지 않습니다'), findsOneWidget);
      expect(repository.calls, hasLength(1));
    },
  );
}
