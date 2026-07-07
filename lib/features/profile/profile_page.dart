import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo/spain_geo.dart';
import '../../core/services/location_service.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/app_user.dart';
import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/location_input_section.dart';
import 'profile_repository.dart';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final _country = TextEditingController();
  final _city = TextEditingController();
  bool _isSaving = false;
  bool _isResolvingLocation = false;
  bool _isEditingLocation = false;
  bool _didSeedProfileLocation = false;
  String? _locationError;

  @override
  void initState() {
    super.initState();
    _country.text = 'Spain';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _useCurrentLocation();
    });
  }

  @override
  void dispose() {
    _country.dispose();
    _city.dispose();
    super.dispose();
  }

  Future<void> _saveLocation() async {
    if (_city.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('스페인 도시를 입력해주세요.')));
      return;
    }
    setState(() => _isSaving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(profileRepositoryProvider)
          .updateLocation(country: 'Spain', city: _city.text);
      ref.invalidate(currentProfileProvider);
      if (mounted) setState(() => _isEditingLocation = false);
      messenger.showSnackBar(const SnackBar(content: Text('프로필을 저장했습니다.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _useCurrentLocation() async {
    if (_isResolvingLocation) return;
    setState(() {
      _isResolvingLocation = true;
      _locationError = null;
    });
    try {
      final location = await const LocationService().getCurrentLocation();
      if (!mounted) return;
      setState(() {
        _country.text = location.country;
        _city.text = location.city;
        _isEditingLocation = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _locationError = _locationMessage(error));
    } finally {
      if (mounted) setState(() => _isResolvingLocation = false);
    }
  }

  void _seedProfileLocation(AppUser user) {
    if (_didSeedProfileLocation) return;
    _didSeedProfileLocation = true;
    if (_city.text.trim().isNotEmpty) {
      return;
    }
    _country.text = SpainGeo.isSpainCountry(user.currentCountry ?? '')
        ? 'Spain'
        : 'Spain';
    _city.text = user.currentCity ?? '';
  }

  String _locationMessage(Object error) {
    return error.toString().replaceFirst('Bad state: ', '');
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(currentProfileProvider);
    return AppPage(
      title: '내 프로필',
      body: AsyncValueView(
        value: profile,
        data: (user) {
          _seedProfileLocation(user);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer,
                        child: Text(
                          user.name.isEmpty ? '?' : user.name.characters.first,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user.name,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(user.email),
                            const SizedBox(height: 6),
                            Text('잔액 ${formatPoints(user.pointBalance)}'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '평점',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      _RatingRow(
                        label: '질문자',
                        average: user.questionerRatingAvg,
                        count: user.questionerRatingCount,
                      ),
                      _RatingRow(
                        label: '답변자',
                        average: user.helperRatingAvg,
                        count: user.helperRatingCount,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '현재 위치',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      LocationInputSection(
                        countryController: _country,
                        cityController: _city,
                        isEditing: _isEditingLocation,
                        isLoading: _isResolvingLocation || _isSaving,
                        errorText: _locationError,
                        lockCountry: true,
                        onEdit: () => setState(() => _isEditingLocation = true),
                        onDone: _saveLocation,
                        onUseCurrentLocation: _useCurrentLocation,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RatingRow extends StatelessWidget {
  const _RatingRow({
    required this.label,
    required this.average,
    required this.count,
  });

  final String label;
  final double average;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const Icon(Icons.star, size: 18, color: Color(0xFFE0A22F)),
          const SizedBox(width: 4),
          Text('${average.toStringAsFixed(1)} · $count개'),
        ],
      ),
    );
  }
}
