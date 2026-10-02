import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_page.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';

void main() {
  testWidgets(
    'offline login recovery offers retry without requiring password entry',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        AuthRepository.sessionTokenKey: 'remembered-token',
      });
      var calls = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((request) async {
          calls++;
          expect(request.url.path, '/api/auth/me');
          expect(request.method, 'GET');
          if (calls == 1) throw http.ClientException('offline');
          return http.Response(
            jsonEncode({
              'id': 'traveler',
              'email': 'traveler@example.com',
              'name': 'Traveler',
              'point_balance': 1000,
              'is_admin': false,
            }),
            200,
          );
        }),
      );
      final auth = AuthRepository(
        api,
        preferences: SharedPreferences.getInstance,
      );
      await auth.restoreSession();
      final router = GoRouter(
        initialLocation: '/auth',
        refreshListenable: auth,
        redirect: (_, state) =>
            auth.currentUser != null && state.matchedLocation == '/auth'
            ? '/home'
            : null,
        routes: [
          GoRoute(path: '/auth', builder: (_, _) => const AuthPage()),
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('restored home')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authRepositoryProvider.overrideWithValue(auth)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('이전 로그인 다시 확인'), findsOneWidget);
      expect(find.textContaining('비밀번호 없이'), findsOneWidget);
      final password = tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .last;
      expect(password.controller?.text, isEmpty);
      await tester.ensureVisible(find.text('이전 로그인 다시 확인'));
      await tester.tap(find.text('이전 로그인 다시 확인'));
      await tester.pumpAndSettle();
      expect(find.text('restored home'), findsOneWidget);
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      auth.dispose();
      api.dispose();
    },
  );
}
