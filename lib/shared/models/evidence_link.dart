class EvidenceLink {
  const EvidenceLink({
    required this.url,
    required this.sourceType,
    this.id,
    this.answerId,
    this.title,
    this.description,
  });

  final String? id;
  final String? answerId;
  final String url;
  final String? title;
  final String? description;
  final String sourceType;

  Map<String, dynamic> toPayload() {
    return {
      'url': url,
      'title': title ?? '',
      'description': description ?? '',
      'source_type': sourceType,
    };
  }

  factory EvidenceLink.fromMap(Map<String, dynamic> map) {
    return EvidenceLink(
      id: map['id'] as String?,
      answerId: map['answer_id'] as String?,
      url: map['url'] as String? ?? '',
      title: map['title'] as String?,
      description: map['description'] as String?,
      sourceType: map['source_type'] as String? ?? 'other',
    );
  }
}
