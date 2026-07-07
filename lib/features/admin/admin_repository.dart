import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../shared/models/helper_application.dart';
import '../../shared/models/helper_region.dart';

final adminRepositoryProvider = Provider<AdminRepository>((ref) {
  return AdminRepository(ref.watch(supabaseClientProvider));
});

final pendingHelperApplicationsProvider =
    FutureProvider<List<AdminHelperApplication>>((ref) {
      return ref.watch(adminRepositoryProvider).fetchHelperApplications();
    });

class AdminRepository {
  const AdminRepository(this._client);

  final SupabaseClient _client;

  Future<List<AdminHelperApplication>> fetchHelperApplications() async {
    final rows = await _client
        .from('helper_applications')
        .select()
        .order('applied_at', ascending: false);

    final applications = (rows as List)
        .map(
          (row) =>
              HelperApplication.fromMap(Map<String, dynamic>.from(row as Map)),
        )
        .toList();

    final result = <AdminHelperApplication>[];
    for (final app in applications) {
      final regionRows = await _client
          .from('helper_regions')
          .select()
          .eq('helper_user_id', app.userId)
          .order('created_at');
      result.add(
        AdminHelperApplication(
          application: app,
          regions: (regionRows as List)
              .map(
                (row) =>
                    HelperRegion.fromMap(Map<String, dynamic>.from(row as Map)),
              )
              .toList(),
        ),
      );
    }
    return result;
  }

  Future<void> reviewApplication({
    required String applicationId,
    required String status,
    String? rejectReason,
  }) async {
    final reviewer = _client.auth.currentUser;
    if (reviewer == null) {
      throw StateError('로그인이 필요합니다.');
    }
    await _client
        .from('helper_applications')
        .update({
          'status': status,
          'reviewed_at': DateTime.now().toUtc().toIso8601String(),
          'reviewed_by': reviewer.id,
          'reject_reason': rejectReason,
        })
        .eq('id', applicationId);
  }
}

class AdminHelperApplication {
  const AdminHelperApplication({
    required this.application,
    required this.regions,
  });

  final HelperApplication application;
  final List<HelperRegion> regions;
}
