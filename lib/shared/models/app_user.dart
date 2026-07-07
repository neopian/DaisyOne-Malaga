class AppUser {
  const AppUser({
    required this.id,
    required this.email,
    required this.name,
    required this.pointBalance,
    required this.isAdmin,
    this.avatarUrl,
    this.currentCountry,
    this.currentCity,
    this.questionerRatingAvg = 0,
    this.helperRatingAvg = 0,
    this.questionerRatingCount = 0,
    this.helperRatingCount = 0,
    this.createdAt,
  });

  final String id;
  final String email;
  final String name;
  final String? avatarUrl;
  final String? currentCountry;
  final String? currentCity;
  final int pointBalance;
  final bool isAdmin;
  final double questionerRatingAvg;
  final double helperRatingAvg;
  final int questionerRatingCount;
  final int helperRatingCount;
  final DateTime? createdAt;

  factory AppUser.fromMap(Map<String, dynamic> map) {
    return AppUser(
      id: map['id'] as String,
      email: map['email'] as String? ?? '',
      name: map['name'] as String? ?? '사용자',
      avatarUrl: map['avatar_url'] as String?,
      currentCountry: map['current_country'] as String?,
      currentCity: map['current_city'] as String?,
      pointBalance: map['point_balance'] as int? ?? 0,
      isAdmin: map['is_admin'] as bool? ?? false,
      questionerRatingAvg:
          (map['questioner_rating_avg'] as num?)?.toDouble() ?? 0,
      helperRatingAvg: (map['helper_rating_avg'] as num?)?.toDouble() ?? 0,
      questionerRatingCount: map['questioner_rating_count'] as int? ?? 0,
      helperRatingCount: map['helper_rating_count'] as int? ?? 0,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
    );
  }
}
