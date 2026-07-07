class HelperApplication {
  const HelperApplication({
    required this.id,
    required this.userId,
    required this.status,
    required this.languages,
    required this.introduction,
    required this.experienceDescription,
    this.appliedAt,
    this.reviewedAt,
    this.reviewedBy,
    this.rejectReason,
  });

  final String id;
  final String userId;
  final String status;
  final List<String> languages;
  final String introduction;
  final String experienceDescription;
  final DateTime? appliedAt;
  final DateTime? reviewedAt;
  final String? reviewedBy;
  final String? rejectReason;

  bool get isApproved => status == 'approved';
  bool get isPending => status == 'pending';

  factory HelperApplication.fromMap(Map<String, dynamic> map) {
    return HelperApplication(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      status: map['status'] as String? ?? 'pending',
      languages: List<String>.from(map['languages'] as List? ?? const []),
      introduction: map['introduction'] as String? ?? '',
      experienceDescription: map['experience_description'] as String? ?? '',
      appliedAt: DateTime.tryParse(map['applied_at'] as String? ?? ''),
      reviewedAt: DateTime.tryParse(map['reviewed_at'] as String? ?? ''),
      reviewedBy: map['reviewed_by'] as String?,
      rejectReason: map['reject_reason'] as String?,
    );
  }
}
