import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/questions/question_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final recreate in [false, true]) {
    test(
      'comment retry after HTTP 408 stays one operation${recreate ? ' after client recreation and HTML proxy error' : ''}',
      () async {
        final applied = <String, String>{};
        final keys = <String>[];
        final clients = <ApiClient>[];
        addTearDown(() {
          for (final client in clients) {
            client.dispose();
          }
        });
        ApiClient makeClient() {
          final client =
              ApiClient(
                  baseUrl: 'https://example.test/api',
                  client: MockClient((request) async {
                    expect(request.method, 'POST');
                    expect(request.url.path, '/api/questions/q/comments');
                    expect(jsonDecode(request.body), {'body': '밤에도 버스가 있나요?'});
                    final key = request.headers['Idempotency-Key']!;
                    keys.add(key);
                    final id = applied.putIfAbsent(
                      key,
                      () => 'comment-${applied.length + 1}',
                    );
                    // An intermediary's timeout cannot prove that the preceding
                    // application operation was never processed.
                    if (keys.length == 1) {
                      return http.Response(
                        recreate
                            ? '<html>Request Timeout</html>'
                            : '{"error":{"code":"REQUEST_TIMEOUT"}}',
                        408,
                      );
                    }
                    return http.Response(jsonEncode({'id': id}), 201);
                  }),
                )
                ..token = 'synthetic-session'
                ..userId = 'traveler';
          clients.add(client);
          return client;
        }

        final first = makeClient();
        Future<void> comment(ApiClient client) => QuestionRepository(
          client,
        ).addComment(questionId: 'q', body: '밤에도 버스가 있나요?');
        await expectLater(
          comment(first),
          throwsA(
            isA<ApiException>().having(
              (error) => error.status,
              'HTTP status',
              408,
            ),
          ),
        );
        await comment(recreate ? makeClient() : first);
        expect(keys, hasLength(2));
        expect(keys[1], keys[0]);
        expect(applied, hasLength(1));
        final preferences = await SharedPreferences.getInstance();
        expect(
          preferences.getKeys().where((key) => key.startsWith('api.pending.')),
          isEmpty,
        );
      },
    );
  }
}
