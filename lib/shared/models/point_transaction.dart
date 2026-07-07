class PointTransaction {
  const PointTransaction({
    required this.id,
    required this.userId,
    required this.type,
    required this.amount,
    this.questionId,
    this.answerId,
    this.createdAt,
  });

  final String id;
  final String userId;
  final String? questionId;
  final String? answerId;
  final String type;
  final int amount;
  final DateTime? createdAt;

  factory PointTransaction.fromMap(Map<String, dynamic> map) {
    return PointTransaction(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      questionId: map['question_id'] as String?,
      answerId: map['answer_id'] as String?,
      type: map['type'] as String? ?? '',
      amount: map['amount'] as int? ?? 0,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
    );
  }
}
