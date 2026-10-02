import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:local_qa_concierge/app/router.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/account/account_settings_page.dart';
import 'package:local_qa_concierge/features/admin/admin_home_page.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/exchange_issues/exchange_issue_repository.dart';
import 'package:local_qa_concierge/features/exchange_issues/exchange_issues_page.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';

import 'exchange_issue_test_support.dart';

void main() {
  late ApiClient api;
  late ExchangeIssueTestAuth auth;
  late ExchangeIssueTestRepository repository;
  setUp(() {
    api = ApiClient(baseUrl: 'https://example.test/api');
    auth = ExchangeIssueTestAuth(api);
    repository = ExchangeIssueTestRepository(api);
  });
  tearDown(() {
    auth.dispose();
    api.dispose();
  });

  Future<GoRouter> mount(
    WidgetTester tester, {
    bool admin = false,
    String? location,
    String? selected,
    double scale = 1,
    Size size = const Size(390, 844),
  }) async {
    if (admin) auth.user = exchangeIssueUser(isAdmin: true);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation:
          location ??
          (admin ? '/admin/exchange-issues' : '/account/exchange-issues'),
      routes: [
        GoRoute(
          path: '/account',
          builder: (_, _) => const AccountSettingsPage(),
        ),
        GoRoute(path: '/admin', builder: (_, _) => const AdminHomePage()),
        GoRoute(
          path: '/account/exchange-issues',
          builder: (_, state) => ExchangeIssuesPage(
            questionId: selected ?? state.uri.queryParameters['question'],
          ),
        ),
        GoRoute(
          path: '/admin/exchange-issues',
          builder: (_, _) => const ExchangeIssuesPage(admin: true),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        retry: (_, _) => null,
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authRepositoryProvider.overrideWithValue(auth),
          exchangeIssueRepositoryProvider.overrideWithValue(repository),
          currentProfileProvider.overrideWith((_) async => auth.currentUser!),
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
    return router;
  }

  Future<void> reveal(
    WidgetTester tester,
    Finder finder, {
    double delta = 250,
  }) async {
    await tester.scrollUntilVisible(
      finder,
      delta,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await reveal(tester, find.text(text));
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  void eligibleRows(List<EligibleExchange> rows) {
    repository.pageResponse = (view, _) async => ExchangeIssuePageData(
      items: view == ExchangeIssueView.eligible ? rows : [],
    );
  }

  test('deep links require login, admin and active role appropriately', () {
    for (final path in ['/account/exchange-issues', '/admin/exchange-issues']) {
      expect(
        authRedirect(initialized: true, user: null, location: path),
        '/auth',
      );
    }
    expect(
      authRedirect(
        initialized: true,
        user: exchangeIssueUser(),
        location: '/admin/exchange-issues',
      ),
      '/home',
    );
    expect(
      authRedirect(
        initialized: true,
        user: exchangeIssueUser(isAdmin: true),
        location: '/admin/exchange-issues',
      ),
      isNull,
    );
    expect(
      authRedirect(
        initialized: true,
        user: exchangeIssueUser(isAdmin: true, isSuspended: true),
        location: '/admin/exchange-issues',
      ),
      '/account',
    );
  });

  testWidgets('loading, error, retry, empty and more keep truthful state', (
    tester,
  ) async {
    final pending = Completer<ExchangeIssuePageData>();
    repository.pageResponse = (view, _) => view == ExchangeIssueView.eligible
        ? pending.future
        : Future.value(const ExchangeIssuePageData(items: []));
    await mount(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.completeError(const ApiException('offline'));
    await tester.pumpAndSettle();
    repository.pageResponse = (_, _) async =>
        const ExchangeIssuePageData(items: []);
    await tapText(tester, '다시 시도');
    expect(find.text('기록할 수 있는 진행 중 질문이 없습니다.'), findsOneWidget);
    repository.pageResponse = (view, cursor) async => ExchangeIssuePageData(
      items: view != ExchangeIssueView.eligible
          ? []
          : [eligibleExchange(cursor == null ? 'first' : 'second')],
      nextCursor: view == ExchangeIssueView.eligible && cursor == null
          ? 'cursor'
          : null,
    );
    await tester.tap(find.byTooltip('기록 새로고침'));
    await tester.pumpAndSettle();
    await tapText(tester, '더 보기');
    await reveal(tester, find.text('진행 second'));
    expect(repository.pageCalls.last.cursor, 'cursor');
    expect(find.text('진행 second'), findsOneWidget);
  });

  testWidgets(
    'hidden reference supports private intake and exact created detail',
    (tester) async {
      eligibleRows([eligibleExchange('hidden', contentAvailable: false)]);
      repository.ownResponse = (id) async =>
          exchangeIssue(id, questionId: 'hidden', details: '내가 적은 내용');
      await mount(tester);
      await tapText(tester, '문제 기록하기');
      expect(find.text('질문 참조 · hidden'), findsNWidgets(2));
      expect(find.textContaining('상대 참여자 참조'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('exchange-issue-details')),
        '내가 적은 내용',
      );
      await tester.tap(find.text('기록 남기기'));
      await tester.pumpAndSettle();
      expect(repository.createCalls.single.questionId, 'hidden');
      expect(repository.ownCalls, ['created-issue']);
      expect(find.text('내가 적은 내용'), findsOneWidget);
      expect(find.text('기록됨'), findsOneWidget);
      expect(find.text('기록 남기기'), findsNothing);
      expect(find.text('해결됨'), findsNothing);
    },
  );

  testWidgets(
    'cancel keeps typed text and uncertain retry freezes same intent',
    (tester) async {
      eligibleRows([eligibleExchange('question')]);
      var attempts = 0;
      repository.createResponse = (_, _, _) async {
        if (attempts++ == 0) {
          throw const ApiException('timeout', code: 'timeout');
        }
        return 'saved';
      };
      await mount(tester);
      await tapText(tester, '문제 기록하기');
      await tester.enterText(
        find.byKey(const ValueKey('exchange-issue-details')),
        '남겨둔 문장',
      );
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await tapText(tester, '문제 기록하기');
      expect(find.text('남겨둔 문장'), findsOneWidget);
      await tester.tap(find.text('기록 남기기'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('exchange-issue-details')),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await tapText(tester, '문제 기록하기');
      await tester.tap(find.text('같은 내용으로 다시 시도'));
      await tester.pumpAndSettle();
      expect(repository.createCalls, hasLength(2));
      expect(repository.createCalls[0], repository.createCalls[1]);
      expect(find.text('남겨둔 문장'), findsNothing);
      expect(find.text('비공개 진행 내용'), findsOneWidget);
    },
  );

  testWidgets('late success after cancel cannot dismiss a newer dialog', (
    tester,
  ) async {
    eligibleRows([eligibleExchange('first'), eligibleExchange('second')]);
    final pending = Completer<String>();
    repository.createResponse = (_, _, _) => pending.future;
    repository.ownResponse = (id) async =>
        exchangeIssue(id, questionId: 'first');
    await mount(tester);
    await tester.ensureVisible(find.text('문제 기록하기').first);
    await tester.tap(find.text('문제 기록하기').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('exchange-issue-details')),
      'first draft',
    );
    await tester.tap(find.text('기록 남기기'));
    await tester.pump();
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('문제 기록하기').last);
    await tester.tap(find.text('문제 기록하기').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('exchange-issue-details')),
      'second draft',
    );
    pending.complete('first-issue');
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('second draft'), findsOneWidget);
    expect(find.text('기록 남기기'), findsOneWidget);
    expect(repository.createCalls, hasLength(1));
  });

  testWidgets('role change clears open editor and ignores pending detail', (
    tester,
  ) async {
    eligibleRows([eligibleExchange('question', ownIssueId: 'old')]);
    final pending = Completer<ExchangeIssueRecord>();
    repository.ownResponse = (_) => pending.future;
    await mount(tester);
    await reveal(tester, find.text('내 기록 열기'));
    await tester.tap(find.text('내 기록 열기'));
    await tester.pump();
    auth.change(exchangeIssueUser(isAdmin: true));
    await tester.pump();
    pending.complete(exchangeIssue('old', details: 'old secret'));
    await tester.pumpAndSettle();
    expect(find.text('old secret'), findsNothing);
    expect(find.text('접근할 수 없음'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'deleted detail clears only its row while another own record stays readable',
    (tester) async {
      var deleted = false;
      repository.pageResponse = (view, _) async => ExchangeIssuePageData(
        items: view == ExchangeIssueView.mine
            ? [
                if (!deleted)
                  exchangeIssue('deleted', questionId: 'private-question'),
                exchangeIssue('other', questionId: 'other-question'),
              ]
            : [],
      );
      repository.ownResponse = (id) async {
        if (id == 'deleted') {
          deleted = true;
          throw const ApiException('missing', status: 404);
        }
        return exchangeIssue(
          'other',
          questionId: 'other-question',
          details: '다른 내 기록 내용',
        );
      };
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('exchange-issues-view-mine')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('기록 자세히 보기').first);
      await tester.tap(find.text('기록 자세히 보기').first);
      await tester.pumpAndSettle();
      expect(find.text('기록을 찾을 수 없음'), findsOneWidget);
      expect(find.textContaining('private-question'), findsNothing);
      expect(find.text('기록 남기기'), findsNothing);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('로그인과 계정 권한'), findsNothing);
      await tapText(tester, '기록 자세히 보기');
      expect(find.text('다른 내 기록 내용'), findsOneWidget);
    },
  );

  testWidgets('one tab denied clears private rows from both tabs immediately', (
    tester,
  ) async {
    final denied = Completer<ExchangeIssuePageData>();
    var loadMine = 0;
    repository.pageResponse = (view, _) async {
      if (view == ExchangeIssueView.mine) {
        if (loadMine++ == 0) {
          return ExchangeIssuePageData(items: [exchangeIssue('private-own')]);
        }
        return denied.future;
      }
      return ExchangeIssuePageData(
        items: [eligibleExchange('private-eligible')],
      );
    };
    await mount(tester);
    expect(find.text('진행 private-eligible'), findsOneWidget);
    await tester.tap(find.byTooltip('기록 새로고침'));
    await tester.pump();
    denied.completeError(const ApiException('denied', status: 403));
    await tester.pumpAndSettle();
    expect(find.textContaining('private-eligible'), findsNothing);
    expect(find.textContaining('private-own'), findsNothing);
    expect(find.textContaining('로그인과 계정 권한'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('exchange-issues-view-mine')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('system back keeps unsent text and returns to the same list', (
    tester,
  ) async {
    eligibleRows([eligibleExchange('question')]);
    final router = await mount(tester);
    await tapText(tester, '문제 기록하기');
    await tester.enterText(
      find.byKey(const ValueKey('exchange-issue-details')),
      '뒤로 가도 유지',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      router.routeInformationProvider.value.uri.path,
      '/account/exchange-issues',
    );
    await tapText(tester, '문제 기록하기');
    expect(find.text('뒤로 가도 유지'), findsOneWidget);
    expect(repository.createCalls, isEmpty);
  });

  testWidgets('admin review note is internal and repeated taps coalesce', (
    tester,
  ) async {
    repository.pageResponse = (view, _) async => ExchangeIssuePageData(
      items: view == ExchangeIssueView.adminOpen
          ? [adminExchangeIssue('admin-issue')]
          : [],
    );
    final pending = Completer<void>();
    repository.reviewResponse = (_, _) => pending.future;
    await mount(tester, admin: true);
    await tapText(tester, '기록 자세히 보기');
    expect(find.text('작성자 참조 · reporter'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('exchange-issue-details')),
      '운영자 내부 기록',
    );
    await tester.tap(find.text('검토 표시'));
    await tester.tap(find.byKey(const ValueKey('exchange-issue-submit')));
    await tester.pump();
    expect(repository.reviewCalls, hasLength(1));
    pending.complete();
    await tester.pumpAndSettle();
    expect(repository.reviewCalls.single.note, '운영자 내부 기록');
    expect(
      find.text('검토 표시를 남겼습니다. 질문 상태와 가상 포인트는 변경되지 않았습니다.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    '320px doubled text supports hidden intake and direct-route back',
    (tester) async {
      eligibleRows([
        eligibleExchange('hidden-long-reference', contentAvailable: false),
      ]);
      final router = await mount(tester, size: const Size(320, 640), scale: 2);
      await tapText(tester, '문제 기록하기');
      await reveal(
        tester,
        find.byKey(const ValueKey('exchange-issue-details')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('exchange-issue-details')),
        '큰 글자 입력',
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/account');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selected hidden exchange opens directly without traversing cursor',
    (tester) async {
      repository.pageResponse = (view, cursor) async => ExchangeIssuePageData(
        items: view != ExchangeIssueView.eligible
            ? []
            : cursor == null
            ? [eligibleExchange('older')]
            : [
                eligibleExchange(
                  'selected',
                  contentAvailable: false,
                  ownIssueId: 'selected-issue',
                ),
              ],
        nextCursor: view == ExchangeIssueView.eligible && cursor == null
            ? 'next'
            : null,
      );
      repository.ownResponse = (id) async =>
          exchangeIssue(id, questionId: 'selected');
      repository.eligibleResponse = (id) async => eligibleExchange(
        id,
        contentAvailable: false,
        ownIssueId: 'selected-issue',
      );
      await mount(tester, selected: 'selected');
      await tester.pumpAndSettle();
      expect(repository.ownCalls, ['selected-issue']);
      expect(repository.eligibleCalls, ['selected']);
      expect(repository.pageCalls.every((call) => call.cursor == null), isTrue);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('비공개 진행 내용'), findsOneWidget);
    },
  );

  testWidgets('account link pushes and back preserves account route', (
    tester,
  ) async {
    final router = await mount(tester, location: '/account');
    await tapText(tester, '진행 문제 기록');
    expect(router.canPop(), isTrue);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/account');
    expect(router.canPop(), isFalse);
  });

  testWidgets('new query on reused page ignores an older selected lookup', (
    tester,
  ) async {
    final old = Completer<EligibleExchange>();
    repository.eligibleResponse = (id) => id == 'old'
        ? old.future
        : Future.value(eligibleExchange(id, contentAvailable: false));
    final router = await mount(
      tester,
      location: '/account/exchange-issues?question=old',
    );
    router.go('/account/exchange-issues?question=new');
    await tester.pumpAndSettle();
    expect(find.text('질문 참조 · new'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('exchange-issue-details')),
      '새 질문 내용',
    );
    old.complete(eligibleExchange('old', ownIssueId: 'old-issue'));
    await tester.pumpAndSettle();
    expect(find.text('새 질문 내용'), findsOneWidget);
    expect(find.textContaining('old'), findsNothing);
    expect(repository.ownCalls, isEmpty);
    expect(repository.eligibleCalls, ['old', 'new']);
  });

  testWidgets('new query replaces only its prior open dialog and draft', (
    tester,
  ) async {
    repository.eligibleResponse = (id) async => eligibleExchange(id);
    final router = await mount(
      tester,
      location: '/account/exchange-issues?question=old',
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('exchange-issue-details')),
      '이전 질문 초안',
    );
    router.go('/account/exchange-issues?question=new');
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('질문 참조 · new'), findsOneWidget);
    expect(find.text('이전 질문 초안'), findsNothing);
    expect(repository.createCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected404 leaves unrelated eligible question usable', (
    tester,
  ) async {
    eligibleRows([eligibleExchange('other')]);
    repository.eligibleResponse = (_) async =>
        throw const ApiException('missing', status: 404);
    await mount(tester, selected: 'gone');
    await tester.pumpAndSettle();
    expect(find.textContaining('선택한 진행을 더 이상 열 수 없습니다.'), findsOneWidget);
    await tapText(tester, '문제 기록하기');
    expect(find.text('기록 남기기'), findsOneWidget);
  });

  testWidgets('admin home exposes review route and returns to exact home', (
    tester,
  ) async {
    final router = await mount(tester, admin: true, location: '/admin');
    await tapText(tester, '진행 문제 검토');
    expect(router.canPop(), isTrue);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/admin');
  });
}
