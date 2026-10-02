import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_page.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';

void main() {
  testWidgets(
    'small enlarged-text login keeps fields, visibility and signup usable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      var requests = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 500);
        }),
      );
      final auth = AuthRepository(
        api,
        preferences: SharedPreferences.getInstance,
      );
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const AuthPage())],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authRepositoryProvider.overrideWithValue(auth)],
          child: MaterialApp.router(
            theme: buildAppTheme(),
            routerConfig: router,
            builder: (_, child) => MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: child!,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final password = find.byType(TextFormField).at(1);
      await tester.ensureVisible(password);
      await tester.enterText(password, 'local-test-password');
      await tester.tap(find.byTooltip('비밀번호 보기'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(password).controller!.text,
        'local-test-password',
      );
      expect(find.byTooltip('비밀번호 숨기기'), findsOneWidget);
      await tester.ensureVisible(find.text('새 계정 만들기'));
      await tester.tap(find.text('새 계정 만들기'));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('가입하기'));
      await tester.tap(find.text('가입하기'));
      await tester.pumpAndSettle();
      expect(find.text('이름을 입력해주세요.'), findsOneWidget);
      expect(requests, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      auth.dispose();
      api.dispose();
    },
  );

  testWidgets(
    'desktop login remains constrained and action contrast is readable',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final api = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((_) async => http.Response('{}', 500)),
      );
      final auth = AuthRepository(
        api,
        preferences: SharedPreferences.getInstance,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authRepositoryProvider.overrideWithValue(auth)],
          child: MaterialApp(theme: buildAppTheme(), home: const AuthPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(TextFormField).first).width,
        lessThan(450),
      );
      expect(
        tester.getTopLeft(find.byType(TextFormField).first).dx,
        greaterThan(650),
      );
      expect(tester.takeException(), isNull);
      final scheme = buildAppTheme().colorScheme;
      final contrast =
          (scheme.onPrimary.computeLuminance() + .05) /
          (scheme.primary.computeLuminance() + .05);
      expect(contrast, greaterThanOrEqualTo(4.5));
      await tester.pumpWidget(const SizedBox.shrink());
      auth.dispose();
      api.dispose();
    },
  );
}
