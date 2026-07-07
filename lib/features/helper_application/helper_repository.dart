import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../shared/models/helper_application.dart';
import '../../shared/models/helper_region.dart';

final helperRepositoryProvider = Provider<HelperRepository>((ref) {
  return HelperRepository(ref.watch(supabaseClientProvider));
});

final helperApplicationProvider = FutureProvider<HelperApplication?>((ref) {
  return ref.watch(helperRepositoryProvider).fetchCurrentApplication();
});

final helperRegionsProvider = FutureProvider<List<HelperRegion>>((ref) {
  return ref.watch(helperRepositoryProvider).fetchCurrentRegions();
});

class HelperRepository {
  const HelperRepository(this._client);

  final SupabaseClient _client;

  Future<HelperApplication?> fetchCurrentApplication() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;
    final row = await _client
        .from('helper_applications')
        .select()
        .eq('user_id', user.id)
        .maybeSingle();
    if (row == null) return null;
    return HelperApplication.fromMap(Map<String, dynamic>.from(row));
  }

  Future<List<HelperRegion>> fetchCurrentRegions() async {
    final user = _client.auth.currentUser;
    if (user == null) return const [];
    final rows = await _client
        .from('helper_regions')
        .select()
        .eq('helper_user_id', user.id)
        .order('created_at');
    return (rows as List)
        .map(
          (row) => HelperRegion.fromMap(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
  }

  Future<void> apply({
    required List<String> languages,
    required List<RegionInput> regions,
    required String introduction,
    required String experienceDescription,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다.');
    }

    await _client.from('helper_applications').upsert({
      'user_id': user.id,
      'status': 'pending',
      'languages': languages,
      'introduction': introduction.trim(),
      'experience_description': experienceDescription.trim(),
      'applied_at': DateTime.now().toUtc().toIso8601String(),
      'reviewed_at': null,
      'reviewed_by': null,
      'reject_reason': null,
    }, onConflict: 'user_id');

    await _client.from('helper_regions').delete().eq('helper_user_id', user.id);
    if (regions.isNotEmpty) {
      await _client
          .from('helper_regions')
          .insert(
            regions
                .map(
                  (region) => {
                    'helper_user_id': user.id,
                    'country': region.country.trim(),
                    'city': region.city.trim(),
                    'region_name': region.regionName?.trim().isEmpty ?? true
                        ? null
                        : region.regionName!.trim(),
                  },
                )
                .toList(),
          );
    }
  }
}

class RegionInput {
  const RegionInput({
    required this.country,
    required this.city,
    this.regionName,
  });

  final String country;
  final String city;
  final String? regionName;
}
