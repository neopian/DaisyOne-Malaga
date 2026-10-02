import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/helper_application/helper_application_page.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alice = AppUser(
  id: 'alice',
  email: 'alice@example.test',
  name: 'Alice',
  pointBalance: 1000,
  isAdmin: false,
);
const _bob = AppUser(
  id: 'bob',
  email: 'bob@example.test',
  name: 'Bob',
  pointBalance: 1000,
  isAdmin: false,
);

class _Auth extends AuthRepository {
  _Auth(super.client);
  AppUser user = _alice;
  @override
  AppUser get currentUser => user;
  void change(AppUser next) {
    user = next;
    notifyListeners();
  }
}

class _Harness {
  late ApiClient api;
  late _Auth auth;
  late GoRouter router;
  final writes = <http.Request>[];
  Completer<http.Response>? reply;
  Future<void> mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    api =
        ApiClient(
            baseUrl: 'https://example.test/api',
            client: MockClient((request) async {
              writes.add(request);
              return reply == null
                  ? http.Response('{"id":"synthetic-application"}', 201)
                  : reply!.future;
            }),
          )
          ..token = 'token-alice'
          ..userId = 'alice';
    auth = _Auth(api);
    router = GoRouter(
      initialLocation: '/helper/apply',
      routes: [
        GoRoute(
          path: '/helper/apply',
          builder: (_, _) => const HelperApplicationPage(),
        ),
        GoRoute(
          path: '/helper/waiting',
          builder: (_, _) => const Scaffold(body: Text('신청 결과 화면')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authRepositoryProvider.overrideWithValue(auth),
          currentProfileProvider.overrideWith((_) async => auth.currentUser),
        ],
        child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      auth.dispose();
      api.dispose();
    });
  }

  Future<void> change(WidgetTester tester, AppUser user) async {
    api.token = 'token-${user.id}';
    api.userId = user.id;
    auth.change(user);
    await tester.pump();
  }

  Future<void> chooseCity(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('guide-city-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('guide-city-select')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('travel-city-search')),
      'Paris',
    );
    await tester.pump();
    await tester.tap(find.byType(ListTile).last);
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester) async {
    await chooseCity(tester);
    final intro = find.byType(TextFormField).at(2),
        experience = find.byType(TextFormField).at(3);
    await tester.ensureVisible(intro);
    await tester.pumpAndSettle();
    await tester.enterText(intro, 'Alice의 현지 경험이 담긴 비공개 신청 내용');
    await tester.ensureVisible(experience);
    await tester.pumpAndSettle();
    await tester.enterText(experience, 'Alice가 파리에서 지내며 직접 쌓은 여행 안내 경험입니다.');
  }
}

void main() {
  testWidgets(
    'same account reauthentication keeps its editable application text',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.fill(tester);
      h.api.token = 'fresh-alice-session';
      h.auth.change(_alice);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).at(2))
            .controller!
            .text,
        contains('Alice'),
      );
      expect(find.text('파리 · 프랑스'), findsOneWidget);
      expect(h.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'guide application text and region never carry into another account',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.fill(tester);
      await h.change(tester, _bob);
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .toList();
      expect(fields[2].controller!.text, isEmpty);
      expect(fields[3].controller!.text, isEmpty);
      expect(find.text('활동할 도시 선택'), findsOneWidget);
      expect(find.byType(InputChip), findsNothing);
      expect(h.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'old account city picker result cannot populate new account draft',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await tester.tap(find.byKey(const ValueKey('guide-city-select')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('travel-city-search')),
        'Paris',
      );
      await tester.pump();
      await h.change(tester, _bob);
      await tester.tap(find.byType(ListTile).last);
      await tester.pumpAndSettle();
      expect(find.text('활동할 도시 선택'), findsOneWidget);
      expect(find.text('파리 · 프랑스'), findsNothing);
      expect(h.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('late application response stays with its initiating account', (
    tester,
  ) async {
    final h = _Harness()..reply = Completer<http.Response>();
    await h.mount(tester);
    await h.fill(tester);
    await tester.ensureVisible(find.text('신청'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('신청'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(h.writes.length, 1);
    expect(h.writes.single.headers['Authorization'], 'Bearer token-alice');
    await h.change(tester, _bob);
    h.reply!.complete(
      http.Response(
        jsonEncode({
          'error': {'code': 'INTERNAL_ERROR'},
        }),
        500,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('신청 결과 화면'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).at(2))
          .controller!
          .text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'current account can submit the application and view its result',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.fill(tester);
      await tester.ensureVisible(find.text('신청'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('신청'));
      await tester.pumpAndSettle();
      expect(h.writes.length, 1);
      expect(find.text('신청 결과 화면'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
