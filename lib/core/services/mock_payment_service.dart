import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'payment_service.dart';
import 'supabase_service.dart';

final paymentServiceProvider = Provider<PaymentService>((ref) {
  return MockPaymentService(ref.watch(supabaseClientProvider));
});

class MockPaymentService implements PaymentService {
  const MockPaymentService(this._client);

  final dynamic _client;

  @override
  Future<void> grantMockCharge({
    required String userId,
    required int amount,
  }) async {
    await _client
        .from('users')
        .update({'point_balance': amount})
        .eq('id', userId);
    await _client.from('point_transactions').insert({
      'user_id': userId,
      'type': 'charge_mock',
      'amount': amount,
    });
  }

  @override
  Future<void> refundQuestion({
    required String userId,
    required String questionId,
    required int amount,
  }) async {
    await _client.rpc(
      'refund_question',
      params: {
        'p_user_id': userId,
        'p_question_id': questionId,
        'p_amount': amount,
      },
    );
  }
}
