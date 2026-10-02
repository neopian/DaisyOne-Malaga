import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/questions/question_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a persisted draft key replays after acknowledgement and client recreation',
    () async {
      final applied = <String, String>{};
      final keys = <String>[];
      var holds = 0;
      Future<http.Response> server(http.Request request) async {
        final key = request.headers['Idempotency-Key']!;
        keys.add(key);
        final actor = request.headers['Authorization'];
        final id = applied.putIfAbsent('$actor|$key', () => 'q-${++holds}');
        return http.Response(jsonEncode({'id': id}), 201);
      }

      Future<String> create(ApiClient api, String requestId) =>
          QuestionRepository(api).createQuestion(
            title: 'Trip question',
            body: 'Where can I buy the ticket?',
            country: 'Spain',
            city: 'Malaga',
            regionName: null,
            category: '교통',
            urgency: '보통',
            rewardPoints: 100,
            latitude: 36.7,
            longitude: -4.4,
            images: [],
            requestId: requestId,
          );
      const draftId = 'draft-11111111-2222-3333-4444';
      final first =
          ApiClient(
              baseUrl: 'https://example.test/api',
              client: MockClient(server),
            )
            ..token = 'actor-a'
            ..userId = 'user-a';
      expect(await create(first, draftId), 'q-1');
      // Server acknowledged, generic retry-key cleanup completed, but the browser
      // crashed before its caller deleted the saved pending draft.
      expect(
        (await SharedPreferences.getInstance()).getKeys().where(
          (key) => key.startsWith('api.pending.'),
        ),
        isEmpty,
      );
      first.dispose();
      final recreated =
          ApiClient(
              baseUrl: 'https://example.test/api',
              client: MockClient(server),
            )
            ..token = 'actor-a'
            ..userId = 'user-a';
      addTearDown(recreated.dispose);
      expect(await create(recreated, draftId), 'q-1');
      expect(holds, 1);
      expect(keys, [draftId, draftId]);
      expect(await create(recreated, 'draft-new-intent-0000'), 'q-2');
      expect(holds, 2);
    },
  );

  test(
    'distinct intentional drafts with identical bodies do not share in-flight work',
    () async {
      final started = Completer<void>();
      final responses = Completer<void>();
      final keys = <String>[];
      final api =
          ApiClient(
              baseUrl: 'https://example.test/api',
              client: MockClient((request) async {
                keys.add(request.headers['Idempotency-Key']!);
                if (keys.length == 2) started.complete();
                await responses.future;
                return http.Response(
                  jsonEncode({'id': request.headers['Idempotency-Key']}),
                  201,
                );
              }),
            )
            ..token = 'session-a'
            ..userId = 'user-a';
      addTearDown(api.dispose);
      final first = api.mutate(
        'questions',
        body: {'body': 'same'},
        idempotencyKey: 'draft-first-0000',
      );
      final second = api.mutate(
        'questions',
        body: {'body': 'same'},
        idempotencyKey: 'draft-second-000',
      );
      await started.future.timeout(const Duration(seconds: 1));
      responses.complete();
      expect(await first, {'id': 'draft-first-0000'});
      expect(await second, {'id': 'draft-second-000'});
      expect(keys, hasLength(2));
    },
  );

  test(
    'an account change does not share another account explicit-key in-flight result',
    () async {
      final firstStarted = Completer<void>();
      final firstResponse = Completer<http.Response>();
      final actors = <String?>[];
      final api =
          ApiClient(
              baseUrl: 'https://example.test/api',
              client: MockClient((request) async {
                actors.add(request.headers['Authorization']);
                if (actors.length == 1) {
                  firstStarted.complete();
                  return firstResponse.future;
                }
                return http.Response('{"id":"b-question"}', 201);
              }),
            )
            ..token = 'session-a'
            ..userId = 'user-a';
      addTearDown(api.dispose);
      final first = api.mutate(
        'questions',
        body: {'body': 'same'},
        idempotencyKey: 'draft-shared-000',
      );
      final firstFailure = expectLater(
        first,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'session_changed'),
        ),
      );
      await firstStarted.future;
      api.token = 'session-b';
      api.userId = 'user-b';
      expect(
        await api.mutate(
          'questions',
          body: {'body': 'same'},
          idempotencyKey: 'draft-shared-000',
        ),
        {'id': 'b-question'},
      );
      firstResponse.complete(http.Response('{"id":"a-question"}', 201));
      await firstFailure;
      expect(actors, ['Bearer session-a', 'Bearer session-b']);
    },
  );

  test('invalid caller key is rejected before HTTP', () async {
    var calls = 0;
    final api =
        ApiClient(
            baseUrl: 'https://example.test/api',
            client: MockClient((_) async {
              calls++;
              return http.Response('{}', 200);
            }),
          )
          ..token = 'session'
          ..userId = 'user';
    addTearDown(api.dispose);
    await expectLater(
      api.mutate('questions', idempotencyKey: 'bad key'),
      throwsA(isA<ApiException>()),
    );
    expect(calls, 0);
  });
}
