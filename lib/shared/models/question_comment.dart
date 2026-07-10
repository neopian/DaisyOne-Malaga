class QuestionComment {
  const QuestionComment({
    required this.id,
    required this.questionId,
    required this.userId,
    required this.body,
    this.authorName,
    this.authorAvatarUrl,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String questionId;
  final String userId;
  final String body;
  final String? authorName;
  final String? authorAvatarUrl;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory QuestionComment.fromMap(Map<String, dynamic> map) {
    final author = map['commenter'] is Map
        ? Map<String, dynamic>.from(map['commenter'] as Map)
        : null;

    return QuestionComment(
      id: map['id'] as String? ?? '',
      questionId: map['question_id'] as String? ?? '',
      userId: map['user_id'] as String? ?? '',
      body: map['body'] as String? ?? '',
      authorName: author?['name'] as String?,
      authorAvatarUrl: author?['avatar_url'] as String?,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? ''),
    );
  }
}
