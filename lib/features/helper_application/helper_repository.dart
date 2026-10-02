import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/api_service.dart';
import '../../shared/models/guide_summary.dart';
import '../../shared/models/helper_application.dart';
import '../../shared/models/helper_region.dart';
import '../auth/auth_repository.dart';

final helperRepositoryProvider = Provider<HelperRepository>(
  (ref) => HelperRepository(ref.watch(apiClientProvider)),
);
final helperApplicationProvider = FutureProvider<HelperApplication?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(helperRepositoryProvider).fetchCurrentApplication();
});
final helperRegionsProvider = FutureProvider<List<HelperRegion>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(helperRepositoryProvider).fetchCurrentRegions();
});

final guideSummaryProvider = FutureProvider<GuideSummary>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(helperRepositoryProvider).fetchGuideSummary();
});

class HelperRepository {
  const HelperRepository(this._client);
  final ApiClient _client;

  Future<GuideSummary> fetchGuideSummary() async =>
      GuideSummary.fromMap(await _client.getMap('guide/me'));

  Future<HelperApplication?> fetchCurrentApplication() async {
    final row = await _client.get('helper/application');
    return row == null ? null : HelperApplication.fromMap(ApiClient.asMap(row));
  }

  Future<List<HelperRegion>> fetchCurrentRegions() async =>
      (await _client.getList(
        'helper/regions',
      )).map(HelperRegion.fromMap).toList();

  Future<void> apply({
    required List<String> languages,
    required List<RegionInput> regions,
    required String introduction,
    required String experienceDescription,
  }) async {
    await _client.mutate(
      'helper/application',
      body: {
        'languages': languages,
        'regions': regions
            .map(
              (region) => {
                'country': region.country.trim(),
                'city': region.city.trim(),
                'region_name': region.regionName?.trim(),
              },
            )
            .toList(),
        'introduction': introduction.trim(),
        'experience_description': experienceDescription.trim(),
      },
    );
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
