import 'answer.dart';
import 'question_comment.dart';

class Question {
  const Question({
    required this.id,
    required this.userId,
    required this.country,
    required this.city,
    required this.category,
    required this.urgency,
    required this.title,
    required this.body,
    required this.rewardPoints,
    required this.status,
    required this.images,
    required this.answers,
    required this.comments,
    this.latitude,
    this.longitude,
    this.assignedHelperUserId,
    this.regionName,
    this.acceptedAnswerId,
    this.createdAt,
    this.updatedAt,
    this.expiresAt,
  });

  final String id;
  final String userId;
  final String? assignedHelperUserId;
  final String country;
  final String city;
  final String? regionName;
  final String category;
  final String urgency;
  final String title;
  final String body;
  final int rewardPoints;
  final String status;
  final String? acceptedAnswerId;
  final double? latitude;
  final double? longitude;
  final List<String> images;
  final List<Answer> answers;
  final List<QuestionComment> comments;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? expiresAt;

  bool get isOpen => status == 'open';
  bool get isAssigned => status == 'assigned';
  bool get isAnswered => status == 'answered';
  bool get isAccepted => status == 'accepted';
  String get locationLabel {
    final region = regionName == null || regionName!.isEmpty
        ? ''
        : ' · $regionName';
    return '$country $city$region';
  }

  Answer? get submittedAnswer => answers.isEmpty ? null : answers.first;

  factory Question.fromMap(Map<String, dynamic> map) {
    final imageRows = map['question_images'] as List? ?? const [];
    final answerRows = map['answers'] as List? ?? const [];
    final commentRows = map['question_comments'] as List? ?? const [];
    final comments =
        commentRows
            .map(
              (row) => row is Map
                  ? QuestionComment.fromMap(Map<String, dynamic>.from(row))
                  : null,
            )
            .whereType<QuestionComment>()
            .toList()
          ..sort((a, b) {
            final aCreatedAt = a.createdAt;
            final bCreatedAt = b.createdAt;
            if (aCreatedAt == null && bCreatedAt == null) return 0;
            if (aCreatedAt == null) return -1;
            if (bCreatedAt == null) return 1;
            return aCreatedAt.compareTo(bCreatedAt);
          });

    return Question(
      id: map['id'] as String? ?? '',
      userId: map['user_id'] as String? ?? '',
      assignedHelperUserId: map['assigned_helper_user_id'] as String?,
      country: map['country'] as String? ?? '',
      city: map['city'] as String? ?? '',
      regionName: map['region_name'] as String?,
      category: map['category'] as String? ?? '기타',
      urgency: map['urgency'] as String? ?? '보통',
      title: map['title'] as String? ?? '',
      body: map['body'] as String? ?? '',
      rewardPoints: (map['reward_points'] as num?)?.toInt() ?? 0,
      status: map['status'] as String? ?? 'open',
      acceptedAnswerId: map['accepted_answer_id'] as String?,
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      images: imageRows
          .map((row) => row is Map ? row['image_url'] as String? ?? '' : '')
          .where((url) => url.isNotEmpty)
          .toList(),
      answers: answerRows
          .map(
            (row) => row is Map
                ? Answer.fromMap(Map<String, dynamic>.from(row))
                : null,
          )
          .whereType<Answer>()
          .toList(),
      comments: comments,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? ''),
      expiresAt: DateTime.tryParse(map['expires_at'] as String? ?? ''),
    );
  }
}
