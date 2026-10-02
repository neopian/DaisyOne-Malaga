/// Mock points only. Charges, holds and rewards are server-owned operations.
abstract class PaymentService {
  Future<void> refundQuestion({required String questionId});
}
