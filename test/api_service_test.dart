import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Matcher _apiError(String code, {int? status}) {
  var matcher = isA<ApiException>().having((error) => error.code, 'code', code);
  if (status != null) {
    matcher = matcher.having((error) => error.status, 'status', status);
  }
  return matcher;
}

class _ControlledPreferences implements SharedPreferences {
  final values = <String, String>{};
  Future<bool> Function(String, String)? onWrite;
  Future<bool> Function(String)? onRemove;

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> setString(String key, String value) async {
    if (onWrite != null) return onWrite!(key, value);
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    if (onRemove != null) return onRemove!(key);
    values.remove(key);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _IncompleteBodyClient extends http.BaseClient {
  final body = StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body.stream, 200);

  @override
  void close() {
    unawaited(body.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  final clients = <ApiClient>[];

  ApiClient createClient(
    Future<http.Response> Function(http.Request) handler, {
    String baseUrl = 'https://example.test/api/v1',
    Duration timeout = const Duration(seconds: 1),
    Future<SharedPreferences> Function()? preferences,
    String? token = 'session-a',
    String? userId = 'user-a',
  }) {
    final client =
        ApiClient(
            baseUrl: baseUrl,
            client: MockClient(handler),
            timeout: timeout,
            preferences: preferences ?? () async => prefs,
          )
          ..token = token
          ..userId = userId;
    clients.add(client);
    return client;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() {
    for (final client in clients) {
      client.dispose();
    }
    clients.clear();
  });

  group('JSON transport', () {
    for (final base in [
      'https://example.test/api/v1',
      'https://example.test/api/v1/',
    ]) {
      test('preserves the API base path for $base', () async {
        final client = createClient((request) async {
          expect(
            request.url.toString(),
            'https://example.test/api/v1/questions?status=open',
          );
          expect(request.headers['Authorization'], 'Bearer session-a');
          expect(request.headers['Accept'], 'application/json');
          return _json([
            {'id': 'question-a'},
          ]);
        }, baseUrl: base);

        expect(await client.getList('questions?status=open'), [
          {'id': 'question-a'},
        ]);
        expect(
          client.resolveMediaUrl('uploads/photo.jpg'),
          'https://example.test/api/v1/uploads/photo.jpg',
        );
      });
    }

    test(
      'rejects missing authentication without sending an HTTP request',
      () async {
        var calls = 0;
        final client = createClient((_) async {
          calls++;
          return _json({});
        }, token: null);

        await expectLater(
          client.get('profile'),
          throwsA(_apiError('unauthorized', status: 401)),
        );
        expect(calls, 0);
      },
    );

    test('keeps structured server errors readable, including UTF-8', () async {
      final client = createClient(
        (_) async => _json({
          'error': {'code': 'insufficient_points', 'message': '포인트가 부족합니다.'},
        }, 409),
      );

      await expectLater(
        client.get('profile'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.status, 'status', 409)
              .having((error) => error.code, 'code', 'insufficient_points')
              .having((error) => error.toString(), 'message', '포인트가 부족합니다.'),
        ),
      );
    });

    test('turns malformed JSON into a readable API error', () async {
      final client = createClient(
        (_) async => http.Response('<html>proxy error</html>', 502),
      );
      await expectLater(
        client.get('profile'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.status, 'status', 502)
              .having(
                (error) => error.message,
                'message',
                isNot(contains('FormatException')),
              ),
        ),
      );
    });

    test('validates map and list response shapes', () async {
      final client = createClient((_) async => _json('unexpected'));
      await expectLater(client.getMap('profile'), throwsA(isA<ApiException>()));
      await expectLater(
        client.getList('questions'),
        throwsA(isA<ApiException>()),
      );
    });

    test('translates network failures', () async {
      final client = createClient(
        (_) async => throw http.ClientException('socket closed'),
      );
      await expectLater(
        client.get('profile'),
        throwsA(_apiError('connection')),
      );
    });

    test('bounds a request that never receives a response', () async {
      final response = Completer<http.Response>();
      final client = createClient(
        (_) => response.future,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(client.get('profile'), throwsA(_apiError('timeout')));
      response.complete(_json({}));
    });

    test('bounds a response whose body never finishes streaming', () async {
      final transport = _IncompleteBodyClient();
      final client = ApiClient(
        baseUrl: 'https://example.test/api/v1',
        client: transport,
        timeout: const Duration(milliseconds: 20),
      )..token = 'session-a';
      clients.add(client);
      await expectLater(client.get('profile'), throwsA(_apiError('timeout')));
    });

    test(
      'clears the active session on a structured unauthorized response',
      () async {
        final client = createClient(
          (_) async => _json({
            'error': {'code': 'unauthorized', 'message': 'Session expired'},
          }, 401),
        );
        var cleared = 0;
        client.onUnauthorized = () async {
          cleared++;
          client.token = null;
        };

        await expectLater(
          client.get('profile'),
          throwsA(
            isA<ApiException>().having((error) => error.status, 'status', 401),
          ),
        );
        expect(cleared, 1);
        expect(client.token, isNull);
      },
    );

    test('clears an active session even when a 401 body is not JSON', () async {
      final client = createClient(
        (_) async => http.Response('Unauthorized', 401),
      );
      var cleared = 0;
      client.onUnauthorized = () async {
        cleared++;
        client.token = null;
      };

      await expectLater(client.get('profile'), throwsA(isA<ApiException>()));
      expect(cleared, 1);
      expect(client.token, isNull);
    });

    for (final nextToken in <String?>[null, 'session-b']) {
      test(
        'rejects a success from a previous session when token becomes $nextToken',
        () async {
          final started = Completer<void>();
          final response = Completer<http.Response>();
          final client = createClient((_) {
            started.complete();
            return response.future;
          });
          final result = client.get('profile');
          await started.future;
          client.token = nextToken;
          response.complete(_json({'id': 'old-user'}));
          await expectLater(result, throwsA(_apiError('session_changed')));
        },
      );
    }

    test('a late unauthorized response cannot clear a newer session', () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final client = createClient((_) {
        started.complete();
        return response.future;
      });
      var cleared = 0;
      client.onUnauthorized = () async {
        cleared++;
      };
      final result = client.get('profile');
      await started.future;
      client.token = 'session-b';
      response.complete(
        _json({
          'error': {'code': 'unauthorized'},
        }, 401),
      );
      await expectLater(result, throwsA(isA<ApiException>()));
      expect(cleared, 0);
      expect(client.token, 'session-b');
    });

    test(
      'an unauthenticated login failure does not clear another session',
      () async {
        final client = createClient((request) async {
          expect(request.headers.containsKey('Authorization'), isFalse);
          return _json({
            'error': {'code': 'invalid_credentials'},
          }, 401);
        });
        var cleared = 0;
        client.onUnauthorized = () async {
          cleared++;
        };
        await expectLater(
          client.mutate(
            'auth/login',
            authenticated: false,
            body: {'email': 'a@example.test', 'password': 'secret'},
          ),
          throwsA(isA<ApiException>()),
        );
        expect(cleared, 0);
        expect(client.token, 'session-a');
      },
    );
  });

  group('durable idempotency', () {
    const body = {'question_id': 'question-a', 'amount': 100};

    test(
      'reuses a key after a connection failure and client recreation',
      () async {
        String? firstKey;
        final firstClient = createClient((request) async {
          firstKey = request.headers['Idempotency-Key'];
          expect(jsonDecode(request.body), body);
          throw http.ClientException('connection lost after submission');
        });
        await expectLater(
          firstClient.mutate('payments', body: body),
          throwsA(_apiError('connection')),
        );
        final storedKeys = prefs.getKeys().where(
          (key) => key.startsWith('api.pending.'),
        );
        expect(storedKeys, hasLength(1));
        expect(prefs.getString(storedKeys.single), firstKey);
        expect(firstKey, isNotEmpty);

        final recreated = createClient((request) async {
          expect(request.headers['Idempotency-Key'], firstKey);
          return _json({'id': 'payment-a'});
        });
        expect(await recreated.mutate('payments', body: body), {
          'id': 'payment-a',
        });
        expect(
          prefs.getKeys().where((key) => key.startsWith('api.pending.')),
          isEmpty,
        );
      },
    );

    test('reuses the key after a timed-out request', () async {
      final keys = <String?>[];
      final lateResponse = Completer<http.Response>();
      final client = createClient((request) {
        keys.add(request.headers['Idempotency-Key']);
        return keys.length == 1
            ? lateResponse.future
            : Future.value(_json({'ok': true}));
      }, timeout: const Duration(milliseconds: 20));
      await expectLater(
        client.mutate('payments', body: body),
        throwsA(_apiError('timeout')),
      );
      await client.mutate('payments', body: body);
      expect(keys, hasLength(2));
      expect(keys[1], keys[0]);
      lateResponse.complete(_json({'ok': true}));
    });

    for (final status in [409, 429, 500, 503]) {
      test('keeps the key after HTTP $status', () async {
        final keys = <String?>[];
        final client = createClient((request) async {
          keys.add(request.headers['Idempotency-Key']);
          return keys.length == 1
              ? _json({
                  'error': {'code': 'retry_later'},
                }, status)
              : _json({'ok': true});
        });
        await expectLater(
          client.mutate('payments', body: body),
          throwsA(isA<ApiException>()),
        );
        await client.mutate('payments', body: body);
        expect(keys, hasLength(2));
        expect(keys[1], keys[0]);
      });
    }

    test(
      'drops a terminal validation failure key before a new attempt',
      () async {
        final keys = <String?>[];
        final client = createClient((request) async {
          keys.add(request.headers['Idempotency-Key']);
          return keys.length == 1
              ? _json({
                  'error': {'code': 'invalid_amount'},
                }, 400)
              : _json({'ok': true});
        });
        await expectLater(
          client.mutate('payments', body: body),
          throwsA(isA<ApiException>()),
        );
        expect(prefs.getKeys(), isEmpty);
        await client.mutate('payments', body: body);
        expect(keys[1], isNot(keys[0]));
      },
    );

    test(
      'deduplicates concurrent same-payload taps into one HTTP request',
      () async {
        final started = Completer<void>();
        final response = Completer<http.Response>();
        var calls = 0;
        final client = createClient((_) {
          calls++;
          if (!started.isCompleted) started.complete();
          return response.future;
        });
        final first = client.mutate('payments', body: body);
        final second = client.mutate(
          'payments',
          body: Map<String, dynamic>.from(body),
        );
        await started.future;
        expect(calls, 1);
        response.complete(_json({'id': 'one-payment'}));
        expect(await Future.wait([first, second]), [
          {'id': 'one-payment'},
          {'id': 'one-payment'},
        ]);
        expect(calls, 1);
      },
    );

    test(
      'uses a new key for a new action after the same payload succeeds',
      () async {
        final keys = <String?>[];
        final client = createClient((request) async {
          keys.add(request.headers['Idempotency-Key']);
          return _json({'ok': true});
        });
        await client.mutate('payments', body: body);
        await client.mutate('payments', body: body);
        expect(keys.toSet(), hasLength(2));
        expect(prefs.getKeys(), isEmpty);
      },
    );

    test(
      'different routes, methods, bodies and users have independent retry keys',
      () async {
        final keys = <String?>[];
        final client = createClient((request) async {
          keys.add(request.headers['Idempotency-Key']);
          throw http.ClientException('offline');
        });
        for (final operation in [
          () => client.mutate('payments', body: body),
          () => client.mutate('refunds', body: body),
          () => client.mutate('payments', body: body, method: 'PATCH'),
          () => client.mutate('payments', body: {...body, 'amount': 200}),
        ]) {
          await expectLater(operation(), throwsA(_apiError('connection')));
        }
        client.userId = 'user-b';
        client.token = 'session-b';
        await expectLater(
          client.mutate('payments', body: body),
          throwsA(_apiError('connection')),
        );
        expect(keys, hasLength(5));
        expect(keys.toSet(), hasLength(5));
      },
    );

    test('does not persist passwords or request bodies', () async {
      final client = createClient(
        (_) async => throw http.ClientException('offline'),
      );
      const secret = 'never-store-this-password';
      await expectLater(
        client.mutate(
          'auth/login',
          authenticated: false,
          body: {'email': 'private@example.test', 'password': secret},
        ),
        throwsA(_apiError('connection')),
      );
      expect(prefs.getKeys(), isEmpty);
      await expectLater(
        client.mutate(
          'questions',
          body: {'content': 'private question content'},
        ),
        throwsA(_apiError('connection')),
      );
      final persisted = prefs
          .getKeys()
          .map((key) => '$key=${prefs.get(key)}')
          .join('\n');
      expect(persisted, isNot(contains(secret)));
      expect(persisted, isNot(contains('private@example.test')));
      expect(persisted, isNot(contains('private question content')));
    });

    test('a rejected retry-key write prevents sending the action', () async {
      final storage = _ControlledPreferences()..onWrite = (_, _) async => false;
      var calls = 0;
      final client = createClient((_) async {
        calls++;
        return _json({});
      }, preferences: () async => storage);
      await expectLater(
        client.mutate('payments', body: body),
        throwsA(_apiError('storage')),
      );
      expect(calls, 0);
    });

    test(
      'a hung retry-key write is bounded and prevents sending the action',
      () async {
        final write = Completer<bool>();
        final storage = _ControlledPreferences()
          ..onWrite = (_, _) => write.future;
        var calls = 0;
        final client = createClient(
          (_) async {
            calls++;
            return _json({});
          },
          preferences: () async => storage,
          timeout: const Duration(milliseconds: 20),
        );
        await expectLater(
          client.mutate('payments', body: body),
          throwsA(_apiError('storage')),
        );
        expect(calls, 0);
        write.complete(true);
      },
    );

    test(
      'successful acknowledgement remains successful if retry-key cleanup fails',
      () async {
        final storage = _ControlledPreferences()
          ..onRemove = (_) async => throw StateError('read-only storage');
        final keys = <String?>[];
        final client = createClient((request) async {
          keys.add(request.headers['Idempotency-Key']);
          return _json({'id': 'one-payment'});
        }, preferences: () async => storage);
        expect(await client.mutate('payments', body: body), {
          'id': 'one-payment',
        });
        expect(await client.mutate('payments', body: body), {
          'id': 'one-payment',
        });
        expect(keys[1], keys[0]);
      },
    );

    test(
      'storage-load failures are readable and prevent sending a mutation',
      () async {
        var calls = 0;
        final client = createClient((_) async {
          calls++;
          return _json({});
        }, preferences: () async => throw StateError('disk unavailable'));
        await expectLater(
          client.mutate('payments', body: body),
          throwsA(_apiError('storage')),
        );
        expect(calls, 0);
      },
    );

    for (final nextToken in <String?>[null, 'session-b']) {
      test(
        'does not dispatch a prepared mutation after token becomes $nextToken',
        () async {
          final storage = Completer<SharedPreferences>();
          var calls = 0;
          final client = createClient((_) async {
            calls++;
            return _json({});
          }, preferences: () => storage.future);
          final result = client.mutate('payments', body: body);
          client.token = nextToken;
          client.userId = nextToken == null ? null : 'user-b';
          storage.complete(prefs);
          await expectLater(result, throwsA(_apiError('session_changed')));
          expect(calls, 0);
        },
      );
    }

    test(
      'a mutation requested without a session cannot run under a subsequent login',
      () async {
        final storage = Completer<SharedPreferences>();
        var calls = 0;
        final client = createClient(
          (_) async {
            calls++;
            return _json({});
          },
          preferences: () => storage.future,
          token: null,
          userId: null,
        );
        final result = client.mutate('payments', body: body);
        client.token = 'newly-signed-in-token';
        client.userId = 'user-b';
        storage.complete(prefs);
        await expectLater(result, throwsA(isA<ApiException>()));
        expect(calls, 0);
      },
    );

    test(
      'a preference-loading timeout is a bounded, readable API failure',
      () async {
        final storage = Completer<SharedPreferences>();
        var calls = 0;
        final client = createClient(
          (_) async {
            calls++;
            return _json({});
          },
          timeout: const Duration(milliseconds: 20),
          preferences: () => storage.future,
        );
        await expectLater(
          client.mutate('payments', body: body),
          throwsA(isA<ApiException>()),
        );
        expect(calls, 0);
        storage.complete(prefs);
      },
    );
  });
}
