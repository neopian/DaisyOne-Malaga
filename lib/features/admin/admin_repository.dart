import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/api_service.dart';
import '../../shared/models/helper_application.dart';
import '../../shared/models/helper_region.dart';
import '../auth/auth_repository.dart';

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => AdminRepository(ref.watch(apiClientProvider)),
);
final pendingHelperApplicationsProvider =
    FutureProvider<List<AdminHelperApplication>>((ref) {
      ref.watch(authStateProvider);
      return ref.watch(adminRepositoryProvider).fetchHelperApplications();
    });

class AdminRepository {
  const AdminRepository(this._client);
  final ApiClient _client;

  Future<List<AdminHelperApplication>> fetchHelperApplications() async =>
      (await _client.getList('admin/applications'))
          .map(
            (row) => AdminHelperApplication(
              application: HelperApplication.fromMap(
                ApiClient.asMap(row['application']),
              ),
              regions: (row['regions'] as List? ?? [])
                  .map(
                    (region) => HelperRegion.fromMap(ApiClient.asMap(region)),
                  )
                  .toList(),
            ),
          )
          .toList();

  Future<void> reviewApplication({
    required String applicationId,
    required String status,
    String? rejectReason,
  }) async {
    await _client.mutate(
      'admin/applications/${Uri.encodeComponent(applicationId)}/review',
      body: {'status': status, 'reject_reason': rejectReason},
    );
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
