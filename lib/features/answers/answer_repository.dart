import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/api_service.dart';
import '../../shared/models/evidence_link.dart';

final answerRepositoryProvider = Provider<AnswerRepository>(
  (ref) => AnswerRepository(ref.watch(apiClientProvider)),
);

class AnswerRepository {
  const AnswerRepository(this._client);
  final ApiClient _client;

  Future<String> submitAnswer({
    required String questionId,
    required String body,
    required String evidenceSummary,
    required String verificationMethod,
    required List<EvidenceLink> links,
    String? requestId,
  }) async {
    final row = ApiClient.asMap(
      await _client.mutate(
        'questions/${Uri.encodeComponent(questionId)}/answers',
        idempotencyKey: requestId,
        body: {
          'body': body,
          'evidence_summary': evidenceSummary,
          'verification_method': verificationMethod,
          'links': links.map((link) => link.toPayload()).toList(),
        },
      ),
    );
    return row['id'] as String;
  }

  Future<void> acceptAnswer({
    required String questionId,
    required String answerId,
  }) async {
    await _client.mutate(
      'questions/${Uri.encodeComponent(questionId)}/answers/${Uri.encodeComponent(answerId)}/accept',
    );
  }
}
