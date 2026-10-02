import '../../core/geo/city_catalog.g.dart';

/// Server-computed activity only. This is not an expertise or identity rating.
class GuideSummary {
  const GuideSummary({
    required this.acceptedAnswerCount,
    required this.earnedMockPoints,
    required this.pendingMockPoints,
    required this.applicationStatus,
    required this.activityRegions,
  });

  final int acceptedAnswerCount;
  final int earnedMockPoints;
  final int pendingMockPoints;
  final String? applicationStatus;
  final List<GuideActivityRegion> activityRegions;

  bool get isApproved => applicationStatus == 'approved';

  factory GuideSummary.fromMap(Map<String, dynamic> map) => GuideSummary(
    acceptedAnswerCount: _recordCount(map, 'accepted_answer_count'),
    earnedMockPoints: _recordCount(map, 'earned_mock_points'),
    pendingMockPoints: _recordCount(map, 'pending_mock_points'),
    applicationStatus: map['application_status'] as String?,
    activityRegions: _regions(map),
  );
}

/// The limited participant-facing record returned with an authorized question.
/// Private wallet amounts and contact details are deliberately not modeled.
class AssignedGuideSummary {
  const AssignedGuideSummary({
    required this.id,
    required this.name,
    required this.acceptedAnswerCount,
    required this.applicationStatus,
    required this.activityRegions,
  });

  final String id;
  final String name;
  final int acceptedAnswerCount;
  final String? applicationStatus;
  final List<GuideActivityRegion> activityRegions;

  factory AssignedGuideSummary.fromMap(Map<String, dynamic> map) =>
      AssignedGuideSummary(
        id: map['id'] as String,
        name: map['name'] as String,
        acceptedAnswerCount: _recordCount(map, 'accepted_answer_count'),
        applicationStatus: map['application_status'] as String?,
        activityRegions: _regions(map),
      );
}

class GuideActivityRegion {
  const GuideActivityRegion({
    required this.country,
    required this.city,
    this.regionName,
  });

  final String country;
  final String city;
  final String? regionName;

  String get label => [
    country,
    city,
    if (regionName?.trim().isNotEmpty == true) regionName!,
  ].where((part) => part.isNotEmpty).join(' · ');

  /// Labels use the shared catalog; authorization remains server-owned.
  String get displayLabel {
    final place = CityCatalog.findCity(country, city);
    if (place == null) return label;
    return GuideActivityRegion(
      country: place.country,
      city: place.city,
      regionName: regionName,
    ).label;
  }

  factory GuideActivityRegion.fromMap(Map<String, dynamic> map) =>
      GuideActivityRegion(
        country: map['country'] as String,
        city: map['city'] as String,
        regionName: map['region_name'] as String?,
      );
}

int _recordCount(Map<String, dynamic> map, String field) {
  final value = map[field];
  // Never present missing, malformed or negative server records as zero activity.
  if (value is! int || value < 0) {
    throw const FormatException('활동 기록 형식을 확인할 수 없습니다. 다시 불러와 주세요.');
  }
  return value;
}

List<GuideActivityRegion> _regions(Map<String, dynamic> map) {
  final rows = map['activity_regions'];
  if (rows is! List) {
    throw const FormatException('활동 지역을 확인할 수 없습니다. 다시 불러와 주세요.');
  }
  return List.unmodifiable(
    rows.map(
      (row) =>
          GuideActivityRegion.fromMap(Map<String, dynamic>.from(row as Map)),
    ),
  );
}
