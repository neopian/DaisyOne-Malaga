import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = {
  'id': 'user-a',
  'email': 'user@example.test',
  'name': 'Test User',
  'point_balance': 300,
  'is_admin': false,
};

http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  final clients = <ApiClient>[];
  final repositories = <AuthRepository>[];

  (ApiClient, AuthRepository) createRepository(
    Future<http.Response> Function(http.Request) handler, {
    Future<SharedPreferences> Function()? preferences,
    Duration timeout = const Duration(seconds: 1),
  }) {
    final client = ApiClient(
      baseUrl: 'https://example.test/api/v1',
      client: MockClient(handler),
      timeout: timeout,
      preferences: () async => prefs,
    );
    final repository = AuthRepository(
      client,
      preferences: preferences ?? () async => prefs,
    );
    clients.add(client);
    repositories.add(repository);
    return (client, repository);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() {
    for (final repository in repositories) {
      repository.dispose();
    }
    for (final client in clients) {
      client.dispose();
    }
    repositories.clear();
    clients.clear();
  });

  group('sign in and Remember me', () {
    test(
      'Remember me persists only the session token, never the password',
      () async {
        final (client, repository) = createRepository((request) async {
          expect(request.url.path, '/api/v1/auth/login');
          expect(request.headers.containsKey('Authorization'), isFalse);
          expect(jsonDecode(request.body), {
            'email': 'user@example.test',
            'password': 'do-not-store-this',
          });
          return _json({'token': 'remembered-token', 'user': _user});
        });

        await repository.signIn(
          email: 'user@example.test',
          password: 'do-not-store-this',
          rememberMe: true,
        );
        expect(
          prefs.getString(AuthRepository.sessionTokenKey),
          'remembered-token',
        );
        expect(prefs.getKeys(), {AuthRepository.sessionTokenKey});
        expect(client.token, 'remembered-token');
        expect(client.userId, 'user-a');
        expect(repository.currentUser?.id, 'user-a');
        expect(repository.initialized, isTrue);
        expect(
          prefs.getKeys().map(prefs.get).join(),
          isNot(contains('do-not-store-this')),
        );
      },
    );

    test('Remember me off removes a previous account token', () async {
      await prefs.setString(
        AuthRepository.sessionTokenKey,
        'old-account-token',
      );
      final (client, repository) = createRepository(
        (_) async => _json({'token': 'memory-only-token', 'user': _user}),
      );

      await repository.signIn(
        email: 'user@example.test',
        password: 'secret',
        rememberMe: false,
      );
      expect(prefs.containsKey(AuthRepository.sessionTokenKey), isFalse);
      expect(prefs.getKeys(), isEmpty);
      expect(client.token, 'memory-only-token');
      expect(repository.currentUser?.id, 'user-a');
    });

    test(
      'signup supports a remembered session without persisting credentials',
      () async {
        final (client, repository) = createRepository((request) async {
          expect(request.url.path, '/api/v1/auth/register');
          expect(jsonDecode(request.body), {
            'email': 'user@example.test',
            'password': 'signup-secret',
            'name': 'Test User',
          });
          return _json({'token': 'signup-token', 'user': _user});
        });
        await repository.signUp(
          email: 'user@example.test',
          password: 'signup-secret',
          name: 'Test User',
          rememberMe: true,
        );
        expect(prefs.getString(AuthRepository.sessionTokenKey), 'signup-token');
        expect(prefs.getKeys(), {AuthRepository.sessionTokenKey});
        expect(client.userId, 'user-a');
      },
    );

    test('a failed login never stores the supplied password', () async {
      final (_, repository) = createRepository(
        (_) async => _json({
          'error': {
            'code': 'invalid_credentials',
            'message': 'Invalid credentials',
          },
        }, 401),
      );
      await expectLater(
        repository.signIn(
          email: 'user@example.test',
          password: 'incorrect-secret',
          rememberMe: true,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(prefs.getKeys(), isEmpty);
      expect(repository.currentUser, isNull);
    });

    test('a malformed login response does not create a session', () async {
      final (client, repository) = createRepository(
        (_) async => _json({'token': '', 'user': _user}),
      );
      await expectLater(
        repository.signIn(email: 'user@example.test', password: 'secret'),
        throwsA(isA<ApiException>()),
      );
      expect(client.token, isNull);
      expect(repository.currentUser, isNull);
      expect(prefs.getKeys(), isEmpty);
    });
  });

  group('restore and clear session', () {
    test(
      'restores a saved token through auth/me and synchronizes account identity',
      () async {
        await prefs.setString(AuthRepository.sessionTokenKey, 'saved-token');
        var calls = 0;
        final (client, repository) = createRepository((request) async {
          calls++;
          expect(request.url.path, '/api/v1/auth/me');
          expect(request.headers['Authorization'], 'Bearer saved-token');
          return _json(_user);
        });
        await Future.wait([
          repository.restoreSession(),
          repository.restoreSession(),
        ]);
        expect(calls, 1);
        expect(repository.initialized, isTrue);
        expect(repository.restorationError, isNull);
        expect(repository.currentUser?.id, 'user-a');
        expect(client.token, 'saved-token');
        expect(client.userId, 'user-a');
      },
    );

    test(
      'no saved session completes initialization without a server request',
      () async {
        var calls = 0;
        final (client, repository) = createRepository((_) async {
          calls++;
          return _json(_user);
        });
        await repository.restoreSession();
        expect(repository.initialized, isTrue);
        expect(repository.currentUser, isNull);
        expect(repository.restorationError, isNull);
        expect(client.token, isNull);
        expect(calls, 0);
      },
    );

    for (final status in [401, 500]) {
      test(
        'restore failure HTTP $status clears access and completes initialization',
        () async {
          await prefs.setString(
            AuthRepository.sessionTokenKey,
            'expired-token',
          );
          final (client, repository) = createRepository(
            (_) async => _json({
              'error': {
                'code': 'unavailable',
                'message': 'Cannot restore session',
              },
            }, status),
          );
          await repository.restoreSession();
          expect(repository.initialized, isTrue);
          expect(repository.restorationError, isNotEmpty);
          expect(repository.currentUser, isNull);
          expect(client.token, isNull);
          expect(client.userId, isNull);
          expect(
            prefs.containsKey(AuthRepository.sessionTokenKey),
            status != 401,
          );
        },
      );
    }

    test(
      'network failure during restore preserves remembered token and completes initialization',
      () async {
        await prefs.setString(AuthRepository.sessionTokenKey, 'saved-token');
        final (client, repository) = createRepository(
          (_) async => throw http.ClientException('offline'),
        );
        await repository.restoreSession();
        expect(repository.initialized, isTrue);
        expect(repository.restorationError, isNotEmpty);
        expect(repository.currentUser, isNull);
        expect(client.token, isNull);
        expect(prefs.getString(AuthRepository.sessionTokenKey), 'saved-token');
        expect(repository.canRetryRestoration, isTrue);
      },
    );

    test(
      'unavailable preference storage cannot strand initialization',
      () async {
        final (client, repository) = createRepository(
          (_) async => _json(_user),
          preferences: () async => throw StateError('storage unavailable'),
        );
        client.token = 'in-memory-token';
        client.userId = 'user-a';
        await repository.restoreSession();
        expect(repository.initialized, isTrue);
        expect(repository.restorationError, isNotEmpty);
        expect(repository.currentUser, isNull);
        expect(client.token, isNull);
        expect(client.userId, isNull);
      },
    );

    test('hung preference storage cannot strand initialization', () async {
      final storage = Completer<SharedPreferences>();
      final (client, repository) = createRepository(
        (_) async => _json(_user),
        preferences: () => storage.future,
        timeout: const Duration(milliseconds: 20),
      );
      await repository.restoreSession().timeout(const Duration(seconds: 1));
      expect(repository.initialized, isTrue);
      expect(repository.restorationError, isNotEmpty);
      expect(client.token, isNull);
      expect(repository.currentUser, isNull);
      storage.complete(prefs);
    });

    test(
      '401 clears the remembered token, current user and transport identity',
      () async {
        final (client, repository) = createRepository((request) async {
          if (request.url.path.endsWith('/auth/login')) {
            return _json({'token': 'saved-token', 'user': _user});
          }
          return _json({
            'error': {'code': 'unauthorized', 'message': 'Session expired'},
          }, 401);
        });
        await repository.signIn(
          email: 'user@example.test',
          password: 'secret',
          rememberMe: true,
        );
        await expectLater(client.get('profile'), throwsA(isA<ApiException>()));
        expect(repository.currentUser, isNull);
        expect(client.token, isNull);
        expect(client.userId, isNull);
        expect(prefs.containsKey(AuthRepository.sessionTokenKey), isFalse);
      },
    );

    test(
      'sign out clears local credentials even if the server is unreachable',
      () async {
        final (client, repository) = createRepository((request) async {
          if (request.url.path.endsWith('/auth/login')) {
            return _json({'token': 'saved-token', 'user': _user});
          }
          expect(request.url.path, '/api/v1/auth/logout');
          throw http.ClientException('offline');
        });
        await repository.signIn(
          email: 'user@example.test',
          password: 'secret',
          rememberMe: true,
        );
        await expectLater(repository.signOut(), throwsA(isA<ApiException>()));
        expect(repository.currentUser, isNull);
        expect(client.token, isNull);
        expect(client.userId, isNull);
        expect(prefs.containsKey(AuthRepository.sessionTokenKey), isFalse);
      },
    );

    test(
      'a late failed restore cannot clear a newer successful login',
      () async {
        await prefs.setString(AuthRepository.sessionTokenKey, 'old-token');
        final started = Completer<void>();
        final restoredProfile = Completer<http.Response>();
        final (client, repository) = createRepository((request) async {
          if (request.url.path.endsWith('/auth/me')) {
            started.complete();
            return restoredProfile.future;
          }
          return _json({
            'token': 'new-token',
            'user': {..._user, 'id': 'user-b'},
          });
        });
        final restoration = repository.restoreSession();
        await started.future;
        await repository.signIn(
          email: 'another@example.test',
          password: 'secret',
          rememberMe: true,
        );
        restoredProfile.complete(_json(_user));
        await restoration;
        expect(repository.initialized, isTrue);
        expect(repository.currentUser?.id, 'user-b');
        expect(client.token, 'new-token');
        expect(client.userId, 'user-b');
        expect(prefs.getString(AuthRepository.sessionTokenKey), 'new-token');
      },
    );

    test('a profile request cannot resurrect a user after logout', () async {
      final started = Completer<void>();
      final profile = Completer<http.Response>();
      final (client, repository) = createRepository((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          return _json({'token': 'saved-token', 'user': _user});
        }
        started.complete();
        return profile.future;
      });
      await repository.signIn(email: 'user@example.test', password: 'secret');
      final request = repository.ensureCurrentProfile();
      await started.future;
      await repository.clearSession();
      profile.complete(_json(_user));
      await expectLater(
        request,
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      expect(repository.currentUser, isNull);
      expect(client.token, isNull);
      expect(client.userId, isNull);
    });
  });
}
