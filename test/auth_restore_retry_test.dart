import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';

const _user = {
  'id': 'traveler-a',
  'email': 'traveler@example.com',
  'name': '여행자',
  'point_balance': 1000,
  'is_admin': false,
};
http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      AuthRepository.sessionTokenKey: 'remembered-token',
    }),
  );

  for (final failure in ['connection', 'timeout', 'server']) {
    test(
      '$failure preserves remembered login but requires online verification before access',
      () async {
        var calls = 0;
        final stalled = Completer<http.Response>();
        final api = ApiClient(
          baseUrl: 'https://example.test/api',
          timeout: const Duration(milliseconds: 20),
          client: MockClient((request) async {
            calls++;
            expect(request.method, 'GET');
            expect(request.url.path, '/api/auth/me');
            expect(request.headers['Authorization'], 'Bearer remembered-token');
            if (calls == 1) {
              if (failure == 'connection') {
                throw http.ClientException('offline');
              }
              if (failure == 'timeout') return stalled.future;
              return _json({
                'error': {'code': 'INTERNAL_ERROR'},
              }, 503);
            }
            return _json(_user);
          }),
        );
        final auth = AuthRepository(
          api,
          preferences: SharedPreferences.getInstance,
        );
        addTearDown(auth.dispose);
        addTearDown(api.dispose);
        final prefs = await SharedPreferences.getInstance();
        await auth.restoreSession();
        expect(auth.initialized, isTrue);
        expect(auth.currentUser, isNull);
        expect(api.token, isNull);
        expect(api.userId, isNull);
        expect(auth.canRetryRestoration, isTrue);
        expect(auth.restorationError, contains('비밀번호 없이'));
        expect(
          prefs.getString(AuthRepository.sessionTokenKey),
          'remembered-token',
        );
        await expectLater(
          api.get('profile'),
          throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
        );
        expect(calls, 1);
        await auth.retryRestoreSession();
        expect(calls, 2);
        expect(auth.currentUser?.id, 'traveler-a');
        expect(api.token, 'remembered-token');
        expect(auth.restorationError, isNull);
        expect(auth.canRetryRestoration, isFalse);
        expect(auth.isRestoring, isFalse);
        if (!stalled.isCompleted) stalled.complete(_json(_user));
      },
    );
  }

  test('definitive401 forgets the token and does not offer retry', () async {
    var calls = 0;
    final api = ApiClient(
      baseUrl: 'https://example.test/api',
      client: MockClient((_) async {
        calls++;
        return _json({
          'error': {'code': 'UNAUTHENTICATED'},
        }, 401);
      }),
    );
    final auth = AuthRepository(
      api,
      preferences: SharedPreferences.getInstance,
    );
    addTearDown(auth.dispose);
    addTearDown(api.dispose);
    await auth.restoreSession();
    expect(auth.currentUser, isNull);
    expect(auth.canRetryRestoration, isFalse);
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        AuthRepository.sessionTokenKey,
      ),
      isFalse,
    );
    await auth.retryRestoreSession();
    expect(calls, 1);
  });

  test(
    'a retry response cannot replace a different account signed in meanwhile',
    () async {
      var meCalls = 0;
      final retryStarted = Completer<void>();
      final retryResponse = Completer<http.Response>();
      final api = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/login') {
            return _json({
              'token': 'new-token',
              'user': {..._user, 'id': 'traveler-b'},
            });
          }
          meCalls++;
          if (meCalls == 1) throw http.ClientException('offline');
          retryStarted.complete();
          return retryResponse.future;
        }),
      );
      final auth = AuthRepository(
        api,
        preferences: SharedPreferences.getInstance,
      );
      addTearDown(auth.dispose);
      addTearDown(api.dispose);
      await auth.restoreSession();
      final retry = auth.retryRestoreSession();
      await retryStarted.future;
      await auth.signIn(
        email: 'new@example.com',
        password: 'new-password',
        rememberMe: true,
      );
      retryResponse.complete(_json(_user));
      await retry;
      expect(auth.currentUser?.id, 'traveler-b');
      expect(api.token, 'new-token');
      expect(auth.canRetryRestoration, isFalse);
      expect(auth.restorationError, isNull);
      expect(
        (await SharedPreferences.getInstance()).getString(
          AuthRepository.sessionTokenKey,
        ),
        'new-token',
      );
    },
  );

  test('explicit logout clears an offline remembered session', () async {
    final api = ApiClient(
      baseUrl: 'https://example.test/api',
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    final auth = AuthRepository(
      api,
      preferences: SharedPreferences.getInstance,
    );
    addTearDown(auth.dispose);
    addTearDown(api.dispose);
    await auth.restoreSession();
    await auth.signOut();
    expect(auth.canRetryRestoration, isFalse);
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        AuthRepository.sessionTokenKey,
      ),
      isFalse,
    );
  });
}
