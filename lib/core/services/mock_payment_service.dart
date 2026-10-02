import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_service.dart';
import 'payment_service.dart';

final paymentServiceProvider = Provider<PaymentService>(
  (ref) => MockPaymentService(ref.watch(apiClientProvider)),
);

class MockPaymentService implements PaymentService {
  const MockPaymentService(this._client);
  final ApiClient _client;
  @override
  Future<void> refundQuestion({required String questionId}) async {
    await _client.mutate('questions/${Uri.encodeComponent(questionId)}/cancel');
  }
}
