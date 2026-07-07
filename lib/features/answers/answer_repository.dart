import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../shared/models/evidence_link.dart';

final answerRepositoryProvider = Provider<AnswerRepository>((ref) {
  return AnswerRepository(ref.watch(supabaseClientProvider));
});

class AnswerRepository {
  const AnswerRepository(this._client);

  final SupabaseClient _client;

  Future<String> submitAnswer({
    required String questionId,
    required String body,
    required String evidenceSummary,
    required String verificationMethod,
    required List<EvidenceLink> links,
  }) async {
    final answerId =
        await _client.rpc(
              'submit_answer_with_evidence',
              params: {
                'p_question_id': questionId,
                'p_body': body,
                'p_evidence_summary': evidenceSummary,
                'p_verification_method': verificationMethod,
                'p_links': links.map((link) => link.toPayload()).toList(),
              },
            )
            as String;
    return answerId;
  }

  Future<void> acceptAnswer({
    required String questionId,
    required String answerId,
  }) {
    return _client.rpc(
      'accept_answer',
      params: {'p_question_id': questionId, 'p_answer_id': answerId},
    );
  }
}
