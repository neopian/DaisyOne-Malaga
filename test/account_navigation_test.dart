import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/account/account_settings_page.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/auth/email_verification_page.dart';
import 'package:local_qa_concierge/features/auth/password_recovery_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';

class NavigationAuth extends AuthRepository {
  NavigationAuth(super.client)
    : super(preferences: SharedPreferences.getInstance);
  bool suspended = false;
  @override
  AppUser get currentUser => AppUser(
    id: 'a',
    email: 'a@example.test',
    name: '여행자',
    pointBalance: 0,
    isAdmin: false,
    isSuspended: suspended,
  );
}

void main() {
  Future<(GoRouter, NavigationAuth)> mount(
    WidgetTester tester,
    String location,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(
      baseUrl: 'https://example.test/api',
      client: MockClient((_) async => http.Response('{}', 500)),
    );
    final auth = NavigationAuth(api);
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('home root')),
        ),
        GoRoute(
          path: '/profile',
          builder: (_, _) => const Scaffold(body: Text('profile root')),
        ),
        GoRoute(
          path: '/auth',
          builder: (_, _) => const Scaffold(body: Text('login root')),
        ),
        GoRoute(
          path: '/account',
          builder: (_, _) => const AccountSettingsPage(),
        ),
        GoRoute(
          path: '/account/verify',
          builder: (_, _) => const EmailVerificationPage(),
        ),
        GoRoute(
          path: '/auth/recovery',
          builder: (_, _) => const PasswordRecoveryPage(),
        ),
      ],
    );
    addTearDown(() {
      router.dispose();
      auth.dispose();
      api.dispose();
    });
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authRepositoryProvider.overrideWithValue(auth),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(),
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (router, auth);
  }

  testWidgets(
    'direct account, verification and recovery routes have usable back fallback',
    (tester) async {
      final (router, auth) = await mount(tester, '/account');
      expect(router.canPop(), isFalse);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('home root'), findsOneWidget);
      router.go('/account/verify');
      await tester.pumpAndSettle();
      expect(find.text('인증 메일 받기'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('home root'), findsOneWidget);
      router.go('/auth/recovery');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('login root'), findsOneWidget);
      auth.suspended = true;
      router.go('/account');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('profile root'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pushed account pages pop one entry and preserve the previous screen',
    (tester) async {
      final (router, _) = await mount(tester, '/home');
      unawaited(router.push('/account'));
      await tester.pumpAndSettle();
      unawaited(router.push('/account/verify'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('계정 및 개인정보'), findsOneWidget);
      expect(router.canPop(), isTrue);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('home root'), findsOneWidget);
      expect(router.canPop(), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
