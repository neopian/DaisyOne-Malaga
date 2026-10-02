import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_qa_concierge/app/router.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/admin/admin_reports_page.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/features/safety/app_info_page.dart';
import 'package:local_qa_concierge/features/safety/blocked_users_page.dart';
import 'package:local_qa_concierge/features/safety/safety_menu.dart';
import 'package:local_qa_concierge/features/safety/safety_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';

const _user = AppUser(
  id: 'traveler',
  email: 'traveler@example.test',
  name: '여행자',
  pointBalance: 1000,
  isAdmin: false,
);
http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class _Safety extends SafetyRepository {
  _Safety() : super(ApiClient(baseUrl: 'https://unused.example.test/api'));
  int reportsSent = 0;
  int unblocksSent = 0;
  int adminFetches = 0;
  Future<void> Function()? onReport;
  Future<void> Function()? onUnblock;
  @override
  Future<void> report({
    required String targetType,
    required String targetId,
    required String reason,
    String? details,
  }) async {
    reportsSent++;
    await onReport?.call();
  }

  @override
  Future<List<BlockedUser>> blockedUsers() async => const [
    BlockedUser(id: 'blocked', name: '차단한 가이드'),
  ];
  @override
  Future<void> unblock(String userId) async {
    unblocksSent++;
    await onUnblock?.call();
  }

  @override
  Future<List<Map<String, dynamic>>> reports(String status) async {
    adminFetches++;
    return [];
  }
}

Future<void> _mount(
  WidgetTester tester,
  Widget widget,
  _Safety repository, {
  double scale = 1,
  AppUser user = _user,
}) async {
  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(
        path: '/test',
        builder: (context, _) => widget is ReportDialog
            ? Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => widget,
                    ),
                    child: const Text('테스트 신고 열기'),
                  ),
                ),
              )
            : widget,
      ),
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('홈')),
      ),
      GoRoute(
        path: '/auth',
        builder: (_, _) => const Scaffold(body: Text('로그인')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        safetyRepositoryProvider.overrideWithValue(repository),
        currentProfileProvider.overrideWith((_) async => user),
        authStateProvider.overrideWith((_) => Stream.value(user)),
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
  await tester.pumpAndSettle();
  if (widget is ReportDialog) {
    await tester.tap(find.text('테스트 신고 열기'));
    await tester.pumpAndSettle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'report retry uses same request key and never stores report text',
    () async {
      final requests = <http.Request>[];
      final client =
          ApiClient(
              baseUrl: 'https://example.test/api',
              client: MockClient((request) async {
                requests.add(request);
                if (requests.length == 1) throw http.ClientException('offline');
                return _json({'id': 'report', 'status': 'open'}, 201);
              }),
            )
            ..token = 'token'
            ..userId = 'traveler';
      addTearDown(client.dispose);
      final repo = SafetyRepository(client);
      Future<void> send() => repo.report(
        targetType: 'question',
        targetId: 'question-id',
        reason: 'privacy',
        details: 'A synthetic sensitive detail',
      );
      await expectLater(send(), throwsA(isA<ApiException>()));
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().any(
          (key) => prefs.get(key).toString().contains('synthetic sensitive'),
        ),
        isFalse,
      );
      await send();
      expect(
        requests[0].headers['idempotency-key'],
        requests[1].headers['idempotency-key'],
      );
      expect(jsonDecode(requests[1].body)['reason'], 'privacy');
    },
  );

  test('account safety routes enforce identity and admin role', () {
    for (final route in [
      '/account',
      '/account/blocked',
      '/account/verify',
      '/admin/reports',
    ]) {
      expect(
        authRedirect(initialized: true, user: null, location: route),
        '/auth',
      );
    }
    for (final route in ['/about', '/auth/recovery']) {
      expect(
        authRedirect(initialized: true, user: null, location: route),
        isNull,
      );
    }
    expect(
      authRedirect(initialized: true, user: _user, location: '/admin/reports'),
      '/home',
    );
  });

  testWidgets('own content has no report or block control', (tester) async {
    await _mount(
      tester,
      const Scaffold(
        body: SafetyMenu(
          targetType: 'question',
          targetId: 'q',
          authorId: 'traveler',
        ),
      ),
      _Safety(),
    );
    expect(find.byTooltip('신고 및 차단'), findsNothing);
  });

  testWidgets('failed report keeps reason and explanation for retry', (
    tester,
  ) async {
    final repository = _Safety()
      ..onReport = () => Future.error(const ApiException('연결이 끊겼습니다.'));
    await _mount(
      tester,
      const ReportDialog(targetType: 'question', targetId: 'q'),
      repository,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('개인정보 노출').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '개인 연락처가 보입니다');
    await tester.tap(find.text('신고 접수'));
    await tester.pumpAndSettle();
    expect(find.text('연결이 끊겼습니다.'), findsOneWidget);
    expect(find.text('개인 연락처가 보입니다'), findsOneWidget);
    expect(find.text('개인정보 노출'), findsOneWidget);
    repository.onReport = () async {};
    await tester.tap(find.text('다시 접수'));
    await tester.pumpAndSettle();
    expect(repository.reportsSent, 2);
    expect(find.text('신고를 접수했습니다.'), findsOneWidget);
  });

  testWidgets(
    'report disables duplicate submission while awaiting acknowledgement',
    (tester) async {
      final pending = Completer<void>();
      final repository = _Safety()..onReport = () => pending.future;
      await _mount(
        tester,
        const ReportDialog(targetType: 'comment', targetId: 'c'),
        repository,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('스팸 · 광고').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('신고 접수'));
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '접수 중…'),
      );
      expect(button.onPressed, isNull);
      expect(repository.reportsSent, 1);
      pending.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('admin screen never fetches reports for ordinary user', (
    tester,
  ) async {
    final repository = _Safety();
    await _mount(tester, const AdminReportsPage(), repository);
    expect(find.text('관리자 권한이 필요합니다.'), findsOneWidget);
    expect(repository.adminFetches, 0);
  });

  testWidgets('failed unblock leaves the user visible with retry', (
    tester,
  ) async {
    final repository = _Safety()
      ..onUnblock = () => Future.error(const ApiException('네트워크 오류'));
    await _mount(tester, const BlockedUsersPage(), repository);
    await tester.tap(find.text('차단 해제'));
    await tester.pumpAndSettle();
    expect(find.text('차단한 가이드'), findsOneWidget);
    expect(find.text('네트워크 오류'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '차단 해제'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    '320px double text safety and public information stay scrollable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _mount(
        tester,
        const ReportDialog(targetType: 'answer', targetId: 'a'),
        _Safety(),
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      await _mount(tester, const AppInfoPage(), _Safety(), scale: 2);
      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
