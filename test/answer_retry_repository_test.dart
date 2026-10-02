import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/answers/answer_repository.dart';
import 'package:local_qa_concierge/shared/models/evidence_link.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'lost acknowledgement and reauthentication replay the same answer after recreation',
    () async {
      var applied = 0;
      var calls = 0;
      final results = <String, String>{};
      final payloads = <String>[];
      final keys = <String>[];
      Future<http.Response> server(http.Request request) async {
        calls++;
        final key = request.headers['Idempotency-Key']!;
        keys.add(key);
        payloads.add(request.body);
        if (calls == 2) {
          return http.Response(
            '{"error":{"code":"UNAUTHENTICATED","message":"Expired"}}',
            401,
          );
        }
        final id = results.putIfAbsent(
          'same-user|$key',
          () => 'answer-${++applied}',
        );
        if (calls == 1) throw http.ClientException('acknowledgement lost');
        return http.Response(jsonEncode({'id': id}), 201);
      }

      ApiClient client(String token) =>
          ApiClient(
              baseUrl: 'https://example.test/api',
              client: MockClient(server),
            )
            ..token = token
            ..userId = 'same-user';
      Future<String> send(ApiClient api) => AnswerRepository(api).submitAnswer(
        questionId: 'q',
        body: 'A carefully checked answer',
        evidenceSummary: 'A current official page',
        verificationMethod: '공식 사이트에서 확인',
        links: const [
          EvidenceLink(url: 'https://example.test', sourceType: 'official'),
        ],
        requestId: 'answer-stable-request-00001',
      );
      final first = client('old-token');
      await expectLater(send(first), throwsA(isA<ApiException>()));
      await expectLater(send(first), throwsA(isA<ApiException>()));
      first.dispose();
      final restored = client('new-token');
      addTearDown(restored.dispose);
      expect(await send(restored), 'answer-1');
      expect(await send(restored), 'answer-1');
      expect(applied, 1);
      expect(keys.toSet(), {'answer-stable-request-00001'});
      expect(payloads.toSet(), hasLength(1));
    },
  );
}
