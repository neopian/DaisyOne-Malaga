import 'evidence_link.dart';

class Answer {
  const Answer({
    required this.id,
    required this.questionId,
    required this.helperUserId,
    required this.body,
    required this.evidenceSummary,
    required this.verificationMethod,
    required this.status,
    required this.isRewarded,
    required this.evidenceLinks,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String questionId;
  final String helperUserId;
  final String body;
  final String evidenceSummary;
  final String verificationMethod;
  final String status;
  final bool isRewarded;
  final List<EvidenceLink> evidenceLinks;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Answer.fromMap(Map<String, dynamic> map) {
    final links = (map['answer_evidence_links'] as List? ?? const [])
        .map(
          (row) => EvidenceLink.fromMap(Map<String, dynamic>.from(row as Map)),
        )
        .toList();

    return Answer(
      id: map['id'] as String,
      questionId: map['question_id'] as String,
      helperUserId: map['helper_user_id'] as String,
      body: map['body'] as String? ?? '',
      evidenceSummary: map['evidence_summary'] as String? ?? '',
      verificationMethod: map['verification_method'] as String? ?? '',
      status: map['status'] as String? ?? 'submitted',
      isRewarded: map['is_rewarded'] as bool? ?? false,
      evidenceLinks: links,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? ''),
    );
  }
}
