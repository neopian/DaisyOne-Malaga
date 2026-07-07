class HelperRegion {
  const HelperRegion({
    required this.id,
    required this.helperUserId,
    required this.country,
    required this.city,
    this.regionName,
  });

  final String id;
  final String helperUserId;
  final String country;
  final String city;
  final String? regionName;

  factory HelperRegion.fromMap(Map<String, dynamic> map) {
    return HelperRegion(
      id: map['id'] as String,
      helperUserId: map['helper_user_id'] as String,
      country: map['country'] as String? ?? '',
      city: map['city'] as String? ?? '',
      regionName: map['region_name'] as String?,
    );
  }
}
