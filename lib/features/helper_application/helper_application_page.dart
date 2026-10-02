import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/app_page.dart';
import '../../core/geo/city_catalog.g.dart';
import '../../shared/widgets/travel_city_picker.dart';
import 'helper_repository.dart';

class HelperApplicationPage extends ConsumerStatefulWidget {
  const HelperApplicationPage({super.key});

  @override
  ConsumerState<HelperApplicationPage> createState() =>
      _HelperApplicationPageState();
}

class _HelperApplicationPageState extends ConsumerState<HelperApplicationPage> {
  final _formKey = GlobalKey<FormState>();
  final _languages = TextEditingController(text: '한국어, 영어');
  final _country = TextEditingController();
  final _city = TextEditingController();
  final _region = TextEditingController();
  final _introduction = TextEditingController();
  final _experience = TextEditingController();
  final _regions = <RegionInput>[];
  bool _isSaving = false;
  String? _selectedCityId;

  @override
  void dispose() {
    _languages.dispose();
    _country.dispose();
    _city.dispose();
    _region.dispose();
    _introduction.dispose();
    _experience.dispose();
    super.dispose();
  }

  void _addRegion() {
    if (_isSaving ||
        !CityCatalog.isSupportedLocation(_country.text, _city.text)) {
      return;
    }
    final regionName = _region.text.trim();
    if (_regions.any(
      (r) =>
          r.country == _country.text &&
          r.city == _city.text &&
          (r.regionName ?? '') == regionName,
    )) {
      return;
    }
    if (_regions.length >= 20) return;
    setState(() {
      _regions.add(
        RegionInput(
          country: _country.text.trim(),
          city: _city.text.trim(),
          regionName: _region.text.trim().isEmpty ? null : _region.text.trim(),
        ),
      );
      _selectedCityId = null;
      _country.clear();
      _city.clear();
      _region.clear();
    });
  }

  Future<void> _submit() async {
    if (_isSaving || !_formKey.currentState!.validate()) return;
    if (_country.text.trim().isNotEmpty && _city.text.trim().isNotEmpty) {
      _addRegion();
    }
    if (_regions.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('활동 지역을 1개 이상 추가해주세요.')));
      return;
    }

    setState(() => _isSaving = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await ref
          .read(helperRepositoryProvider)
          .apply(
            languages: _languages.text
                .split(',')
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toList(),
            regions: _regions,
            introduction: _introduction.text,
            experienceDescription: _experience.text,
          );
      container.invalidate(helperApplicationProvider);
      container.invalidate(helperRegionsProvider);
      container.invalidate(guideSummaryProvider);
      if (mounted) router.go('/helper/waiting');
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPage(
      title: '답변자 신청',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _languages,
                decoration: const InputDecoration(
                  labelText: '가능한 언어',
                  prefixIcon: Icon(Icons.translate),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? '언어를 입력해주세요.'
                    : null,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('guide-city-select'),
                onPressed: _isSaving
                    ? null
                    : () async {
                        final city = await showTravelCityPicker(context);
                        if (!mounted || _isSaving || city == null) return;
                        setState(() {
                          _selectedCityId = city.id;
                          _country.text = city.country;
                          _city.text = city.city;
                        });
                      },
                icon: const Icon(Icons.location_city_outlined),
                label: Text(
                  _selectedCityId == null
                      ? '활동할 도시 선택'
                      : '${CityCatalog.findCity(_country.text, _city.text)?.cityKo ?? _city.text} · ${CityCatalog.countryLabel(_country.text)}',
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '잘 아는 도시를 선택해주세요. 신청은 운영자 검토 후 반영되며 답변 가능 인원을 보장하지 않습니다.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _region,
                decoration: const InputDecoration(
                  labelText: '지역',
                  prefixIcon: Icon(Icons.place_outlined),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _isSaving ? null : _addRegion,
                icon: const Icon(Icons.add_location_alt_outlined),
                label: const Text('지역 추가'),
              ),
              if (_regions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final region in _regions)
                      InputChip(
                        label: Text(
                          '${CityCatalog.countryLabel(region.country)} · ${CityCatalog.findCity(region.country, region.city)?.cityKo ?? region.city}'
                          '${region.regionName == null ? '' : ' · ${region.regionName}'}',
                        ),
                        onDeleted: _isSaving
                            ? null
                            : () => setState(() => _regions.remove(region)),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _introduction,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '자기소개',
                  alignLabelWithHint: true,
                ),
                validator: (value) => value == null || value.trim().length < 10
                    ? '자기소개를 입력해주세요.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _experience,
                minLines: 4,
                maxLines: 7,
                decoration: const InputDecoration(
                  labelText: '현지 경험 설명',
                  alignLabelWithHint: true,
                ),
                validator: (value) => value == null || value.trim().length < 20
                    ? '현지 경험을 조금 더 적어주세요.'
                    : null,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _isSaving ? null : _submit,
                icon: _isSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_user_outlined),
                label: const Text('신청'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
