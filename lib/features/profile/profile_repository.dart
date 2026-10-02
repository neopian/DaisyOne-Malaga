import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/api_service.dart';
import '../../shared/models/app_user.dart';
import '../../shared/models/point_transaction.dart';
import '../auth/auth_repository.dart';

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(ref.watch(apiClientProvider)),
);

final currentProfileProvider = FutureProvider<AppUser>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(profileRepositoryProvider).fetchCurrentProfile();
});

final pointTransactionsProvider = FutureProvider<List<PointTransaction>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(profileRepositoryProvider).fetchPointTransactions();
});

class ProfileRepository {
  const ProfileRepository(this._client);
  final ApiClient _client;

  Future<AppUser> fetchCurrentProfile() async =>
      AppUser.fromMap(await _client.getMap('profile'));

  Future<void> updateLocation({
    required String country,
    required String city,
  }) async {
    await _client.mutate(
      'profile',
      method: 'PATCH',
      body: {'current_country': country.trim(), 'current_city': city.trim()},
    );
  }

  Future<List<PointTransaction>> fetchPointTransactions() async =>
      (await _client.getList('points')).map(PointTransaction.fromMap).toList();
}
