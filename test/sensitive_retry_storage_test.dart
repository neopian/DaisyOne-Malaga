import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final path in ['account/export', 'account/delete']) {
    test(
      '$path retries in memory without a password-derived storage lookup',
      () async {
        final keys = <String>[];
        var preferenceReads = 0;
        final client =
            ApiClient(
                baseUrl: 'https://example.test/api',
                preferences: () async {
                  preferenceReads++;
                  return SharedPreferences.getInstance();
                },
                client: MockClient((request) async {
                  keys.add(request.headers['idempotency-key']!);
                  if (keys.length == 1) {
                    throw http.ClientException('acknowledgement unavailable');
                  }
                  return http.Response(jsonEncode({'ok': true}), 200);
                }),
              )
              ..token = 'synthetic-session'
              ..userId = 'synthetic-user';
        addTearDown(client.dispose);
        final body = {
          'password': 'not-a-real-password',
          if (path.endsWith('delete')) 'confirmation': 'DELETE',
        };
        await expectLater(
          client.mutate(path, body: body),
          throwsA(isA<ApiException>()),
        );
        await client.mutate(path, body: body);
        expect(
          keys[0],
          keys[1],
          reason: 'Current-process retry remains duplicate-safe',
        );
        expect(
          preferenceReads,
          0,
          reason: 'No durable lookup can encode a reauthentication secret',
        );
        expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      },
    );
  }
  test('ordinary answer retry still survives a new client instance', () async {
    final keys = <String>[];
    ApiClient client(bool fail) =>
        ApiClient(
            baseUrl: 'https://example.test/api',
            client: MockClient((request) async {
              keys.add(request.headers['idempotency-key']!);
              if (fail) throw http.ClientException('offline');
              return http.Response('{"id":"answer"}', 200);
            }),
          )
          ..token = 'synthetic-session'
          ..userId = 'synthetic-user';
    final first = client(true), second = client(false);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    const body = {'body': 'Synthetic evidence-backed answer'};
    await expectLater(
      first.mutate('questions/q/answers', body: body),
      throwsA(isA<ApiException>()),
    );
    expect((await SharedPreferences.getInstance()).getKeys(), isNotEmpty);
    await second.mutate('questions/q/answers', body: body);
    expect(keys[0], keys[1]);
  });
}
