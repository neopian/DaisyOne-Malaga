import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../shared/models/app_user.dart';
import '../../shared/models/point_transaction.dart';

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref.watch(supabaseClientProvider));
});

final currentProfileProvider = FutureProvider<AppUser>((ref) {
  return ref.watch(profileRepositoryProvider).fetchCurrentProfile();
});

final pointTransactionsProvider = FutureProvider<List<PointTransaction>>((ref) {
  return ref.watch(profileRepositoryProvider).fetchPointTransactions();
});

class ProfileRepository {
  const ProfileRepository(this._client);

  final SupabaseClient _client;

  Future<AppUser> fetchCurrentProfile() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다.');
    }
    final row = await _client.from('users').select().eq('id', user.id).single();
    return AppUser.fromMap(Map<String, dynamic>.from(row));
  }

  Future<void> updateLocation({
    required String country,
    required String city,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다.');
    }
    await _client
        .from('users')
        .update({
          'current_country': country.trim(),
          'current_city': city.trim(),
        })
        .eq('id', user.id);
  }

  Future<List<PointTransaction>> fetchPointTransactions() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다.');
    }
    final rows = await _client
        .from('point_transactions')
        .select()
        .eq('user_id', user.id)
        .order('created_at', ascending: false);
    return (rows as List)
        .map(
          (row) =>
              PointTransaction.fromMap(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
  }
}
