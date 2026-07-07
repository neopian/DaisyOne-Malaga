abstract class PaymentService {
  Future<void> grantMockCharge({required String userId, required int amount});

  Future<void> refundQuestion({
    required String userId,
    required String questionId,
    required int amount,
  });
}
