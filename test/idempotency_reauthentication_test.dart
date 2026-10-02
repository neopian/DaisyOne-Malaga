import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a late logout completion cannot clear a newer remembered login',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final logoutStarted = Completer<void>();
      final logoutResponse = Completer<http.Response>();
      var logins = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/logout') {
            logoutStarted.complete();
            return logoutResponse.future;
          }
          logins++;
          return http.Response(
            jsonEncode({
              'token': 'session-$logins',
              'user': {
                'id': 'user-$logins',
                'email': 'user$logins@example.com',
                'name': '사용자',
                'point_balance': 1000,
                'is_admin': false,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final auth = AuthRepository(
        api,
        preferences: SharedPreferences.getInstance,
      );
      addTearDown(auth.dispose);
      addTearDown(api.dispose);
      await auth.signIn(email: 'a@example.com', password: 'password-a');
      final logout = auth.signOut();
      final lateResult = expectLater(
        logout,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'session_changed'),
        ),
      );
      await logoutStarted.future;
      // Concurrent expiry reveals the login screen before logout responds.
      await auth.clearSession();
      await auth.signIn(
        email: 'b@example.com',
        password: 'password-b',
        rememberMe: true,
      );
      logoutResponse.complete(http.Response('{"ok":true}', 200));
      await lateResult;
      expect(auth.currentUser?.id, 'user-2');
      expect(api.token, 'session-2');
      expect(prefs.getString(AuthRepository.sessionTokenKey), 'session-2');
    },
  );

  test('lost create acknowledgement survives 401, same-account reauth and client recreation', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const user = {
      'id': 'questioner',
      'email': 'owner@example.com',
      'name': '질문자',
      'point_balance': 900,
      'is_admin': false,
    };
    const body = {
      'title': '질문 제목',
      'body': '재시도에도 보상 포인트는 한 번만 보류됩니다.',
      'reward_points': 100,
    };
    final applied = <String, String>{};
    final requestKeys = <String>[];
    var questionRequests = 0;
    var logins = 0;
    var holds = 0;
    http.Response json(Object value, [int status = 200]) => http.Response(
      jsonEncode(value),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    Future<http.Response> server(http.Request request) async {
      if (request.url.path == '/api/auth/login') {
        logins++;
        return json({'token': 'session-$logins', 'user': user});
      }
      expect(request.url.path, '/api/questions');
      expect(jsonDecode(request.body), body);
      questionRequests++;
      final key = request.headers['Idempotency-Key']!;
      requestKeys.add(key);
      if (questionRequests == 2) {
        // Auth middleware rejects before reaching the idempotency replay lookup.
        return json({
          'error': {'code': 'UNAUTHENTICATED', 'message': 'Session expired'},
        }, 401);
      }
      final questionId = applied.putIfAbsent(key, () {
        holds++;
        return 'question-$holds';
      });
      if (questionRequests == 1) {
        // The server transaction committed, but its acknowledgement was lost.
        throw http.ClientException('connection closed after commit');
      }
      return json({'id': questionId});
    }

    final firstClient = ApiClient(
      baseUrl: 'https://example.test/api',
      client: MockClient(server),
    );
    final firstAuth = AuthRepository(
      firstClient,
      preferences: SharedPreferences.getInstance,
    );
    await firstAuth.signIn(
      email: 'owner@example.com',
      password: 'test-password',
    );
    await expectLater(
      firstClient.mutate('questions', body: body),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'connection')),
    );
    final pendingKeys = prefs
        .getKeys()
        .where((key) => key.startsWith('api.pending.'))
        .toSet();
    expect(pendingKeys, hasLength(1));
    await expectLater(
      firstClient.mutate('questions', body: body),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
    );
    expect(firstAuth.currentUser, isNull);
    expect(
      prefs.getKeys().where((key) => key.startsWith('api.pending.')).toSet(),
      pendingKeys,
    );
    firstAuth.dispose();
    firstClient.dispose();

    final recreatedClient = ApiClient(
      baseUrl: 'https://example.test/api',
      client: MockClient(server),
    );
    final recreatedAuth = AuthRepository(
      recreatedClient,
      preferences: SharedPreferences.getInstance,
    );
    addTearDown(recreatedAuth.dispose);
    addTearDown(recreatedClient.dispose);
    await recreatedAuth.signIn(
      email: 'owner@example.com',
      password: 'test-password',
    );
    final result = await recreatedClient.mutate('questions', body: body);
    expect(result, {'id': 'question-1'});
    expect(holds, 1);
    expect(applied, hasLength(1));
    expect(requestKeys, hasLength(3));
    expect(requestKeys.toSet(), hasLength(1));
    expect(
      prefs.getKeys().where((key) => key.startsWith('api.pending.')),
      isEmpty,
    );
  });
}
