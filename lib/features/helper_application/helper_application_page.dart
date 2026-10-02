import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/app_page.dart';
import '../../core/geo/city_catalog.g.dart';
import '../../core/services/api_service.dart';
import '../../shared/widgets/travel_city_picker.dart';
import '../auth/auth_repository.dart';
import 'helper_repository.dart';

class HelperApplicationPage extends ConsumerStatefulWidget {
  const HelperApplicationPage({super.key});

  @override
  ConsumerState<HelperApplicationPage> createState() =>
      _HelperApplicationPageState();
}

class _HelperApplicationPageState extends ConsumerState<HelperApplicationPage> {
  var _formKey = GlobalKey<FormState>();
  late final AuthRepository _auth;
  late final ApiClient _api;
  late (String?, String?) _accountScope;
  int _formRevision = 0;
  final _languages = TextEditingController(text: '한국어, 영어');
  final _country = TextEditingController();
  final _city = TextEditingController();
  final _region = TextEditingController();
  final _introduction = TextEditingController();
  final _experience = TextEditingController();
  final _regions = <RegionInput>[];
  bool _isSaving = false;
  String? _selectedCityId;

  (String?, String?) get _currentScope => (_auth.currentUser?.id, _api.token);

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authRepositoryProvider);
    _api = ref.read(apiClientProvider);
    _accountScope = _currentScope;
    _auth.addListener(_onAccountChanged);
  }

  void _onAccountChanged() {
    if (!mounted || _accountScope == _currentScope) return;
    final ownerChanged = _accountScope.$1 != _currentScope.$1;
    setState(() {
      _accountScope = _currentScope;
      _formRevision++;
      _isSaving = false;
      // Reauthentication cancels old work but need not erase this same
      // person's editable text. A different account receives a blank form.
      if (ownerChanged) {
        _formKey = GlobalKey<FormState>();
        _languages.text = '한국어, 영어';
        _country.clear();
        _city.clear();
        _region.clear();
        _introduction.clear();
        _experience.clear();
        _regions.clear();
        _selectedCityId = null;
      }
    });
  }

  @override
  void dispose() {
    _formRevision++;
    _auth.removeListener(_onAccountChanged);
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
    final scope = _currentScope;
    final revision = _formRevision;
    if (scope.$1 == null || scope.$2 == null) return;
    bool isCurrent() =>
        mounted && revision == _formRevision && scope == _currentScope;
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
      if (!isCurrent()) return;
      container.invalidate(helperApplicationProvider);
      container.invalidate(helperRegionsProvider);
      container.invalidate(guideSummaryProvider);
      router.go('/helper/waiting');
    } catch (error) {
      if (isCurrent() && messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (isCurrent()) setState(() => _isSaving = false);
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
                enabled: !_isSaving,
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
                        final revision = _formRevision;
                        final scope = _currentScope;
                        final city = await showTravelCityPicker(context);
                        if (!mounted ||
                            _isSaving ||
                            city == null ||
                            revision != _formRevision ||
                            scope != _currentScope) {
                          return;
                        }
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
                enabled: !_isSaving,
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
                enabled: !_isSaving,
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
                enabled: !_isSaving,
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
