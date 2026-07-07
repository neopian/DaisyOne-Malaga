import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/app_page.dart';
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
    if (_country.text.trim().isEmpty || _city.text.trim().isEmpty) return;
    setState(() {
      _regions.add(
        RegionInput(
          country: _country.text.trim(),
          city: _city.text.trim(),
          regionName: _region.text.trim().isEmpty ? null : _region.text.trim(),
        ),
      );
      _country.clear();
      _city.clear();
      _region.clear();
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_regions.isEmpty &&
        _country.text.trim().isNotEmpty &&
        _city.text.trim().isNotEmpty) {
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
      ref.invalidate(helperApplicationProvider);
      ref.invalidate(helperRegionsProvider);
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
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _country,
                      decoration: const InputDecoration(labelText: '국가'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _city,
                      decoration: const InputDecoration(labelText: '도시'),
                    ),
                  ),
                ],
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
                onPressed: _addRegion,
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
                          '${region.country} ${region.city}'
                          '${region.regionName == null ? '' : ' · ${region.regionName}'}',
                        ),
                        onDeleted: () =>
                            setState(() => _regions.remove(region)),
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
