import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants/app_constants.dart';
import '../../core/geo/spain_geo.dart';
import '../../core/services/location_service.dart';
import '../../core/services/mvp_rules.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/app_user.dart';
import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/location_input_section.dart';
import '../profile/profile_repository.dart';
import 'question_repository.dart';

class CreateQuestionPage extends ConsumerStatefulWidget {
  const CreateQuestionPage({super.key});

  @override
  ConsumerState<CreateQuestionPage> createState() => _CreateQuestionPageState();
}

class _CreateQuestionPageState extends ConsumerState<CreateQuestionPage> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _country = TextEditingController();
  final _city = TextEditingController();
  final _region = TextEditingController();
  final _reward = TextEditingController(text: '100');
  final _picker = ImagePicker();
  final _images = <XFile>[];
  String _category = AppConstants.categories.first;
  String _urgency = AppConstants.urgencies.first;
  bool _isSaving = false;
  bool _isResolvingLocation = false;
  bool _isEditingLocation = false;
  bool _didSeedProfileLocation = false;
  String? _locationError;
  double? _latitude;
  double? _longitude;

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
    _title.dispose();
    _body.dispose();
    _country.dispose();
    _city.dispose();
    _region.dispose();
    _reward.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await _picker.pickMultiImage(limit: 4);
    if (picked.isEmpty) return;
    setState(() {
      _images
        ..clear()
        ..addAll(picked.take(4));
    });
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
        _region.text = location.regionName ?? '';
        _latitude = location.latitude;
        _longitude = location.longitude;
        _isEditingLocation = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _locationError = _locationMessage(error));
    } finally {
      if (mounted) setState(() => _isResolvingLocation = false);
    }
  }

  void _seedProfileLocation(AppUser? profile) {
    if (_didSeedProfileLocation || profile == null) return;
    _didSeedProfileLocation = true;
    if (_city.text.trim().isNotEmpty) {
      return;
    }
    _country.text = 'Spain';
    _city.text = profile.currentCity ?? '';
  }

  bool _hasRequiredLocation() {
    return SpainGeo.isSpainCountry(_country.text) &&
        _city.text.trim().isNotEmpty;
  }

  void _finishLocationEdit() {
    if (!_hasRequiredLocation()) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('스페인 도시를 입력해주세요.')));
      return;
    }
    final place = SpainGeo.placeForCity(_city.text);
    setState(() {
      _country.text = 'Spain';
      _latitude = place.latitude;
      _longitude = place.longitude;
      _isEditingLocation = false;
    });
  }

  String _locationMessage(Object error) {
    return error.toString().replaceFirst('Bad state: ', '');
  }

  Future<void> _submit() async {
    if (!_hasRequiredLocation()) {
      setState(() => _isEditingLocation = true);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('스페인 도시를 입력해주세요.')));
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null) return;
    final rewardPoints = int.parse(_reward.text);
    if (!MvpRules.canCreateQuestion(
      pointBalance: profile.pointBalance,
      rewardPoints: rewardPoints,
    )) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('보상 포인트가 잔액보다 큽니다.')));
      return;
    }

    setState(() => _isSaving = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      final coordinates = _coordinatesForSubmit();
      final id = await ref
          .read(questionRepositoryProvider)
          .createQuestion(
            title: _title.text.trim(),
            body: _body.text.trim(),
            country: _country.text.trim(),
            city: _city.text.trim(),
            regionName: _region.text.trim().isEmpty
                ? null
                : _region.text.trim(),
            category: _category,
            urgency: _urgency,
            rewardPoints: rewardPoints,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude,
            images: _images,
          );
      ref.invalidate(questionsProvider);
      ref.invalidate(currentProfileProvider);
      if (mounted) router.go('/questions/$id');
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  ({double latitude, double longitude}) _coordinatesForSubmit() {
    final latitude = _latitude;
    final longitude = _longitude;
    if (latitude != null &&
        longitude != null &&
        SpainGeo.isWithinSpainBounds(
          latitude: latitude,
          longitude: longitude,
        )) {
      return (latitude: latitude, longitude: longitude);
    }
    final place = SpainGeo.placeForCity(_city.text);
    return (latitude: place.latitude, longitude: place.longitude);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(currentProfileProvider).asData?.value;
    _seedProfileLocation(profile);
    return AppPage(
      title: '질문 등록',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (profile != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('잔액 ${formatPoints(profile.pointBalance)}'),
                ),
              TextFormField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: '질문 제목',
                  prefixIcon: Icon(Icons.title),
                ),
                validator: (value) => value == null || value.trim().length < 4
                    ? '제목을 입력해주세요.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _body,
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: '질문 내용',
                  alignLabelWithHint: true,
                ),
                validator: (value) => value == null || value.trim().length < 10
                    ? '상황을 조금 더 적어주세요.'
                    : null,
              ),
              const SizedBox(height: 12),
              LocationInputSection(
                countryController: _country,
                cityController: _city,
                regionController: _region,
                isEditing: _isEditingLocation,
                isLoading: _isResolvingLocation,
                errorText: _locationError,
                lockCountry: true,
                onEdit: () => setState(() => _isEditingLocation = true),
                onDone: _finishLocationEdit,
                onUseCurrentLocation: _useCurrentLocation,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _category,
                decoration: const InputDecoration(labelText: '카테고리'),
                items: AppConstants.categories
                    .map(
                      (value) =>
                          DropdownMenuItem(value: value, child: Text(value)),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _category = value!),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: AppConstants.urgencies
                    .map(
                      (urgency) =>
                          ButtonSegment(value: urgency, label: Text(urgency)),
                    )
                    .toList(),
                selected: {_urgency},
                onSelectionChanged: (value) =>
                    setState(() => _urgency = value.single),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _reward,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '보상 포인트',
                  prefixIcon: Icon(Icons.toll_outlined),
                ),
                validator: (value) {
                  final points = int.tryParse(value ?? '');
                  if (points == null || points <= 0) return '1 이상 입력해주세요.';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(
                  _images.isEmpty ? '사진 첨부' : '사진 ${_images.length}장 선택됨',
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _isSaving ? null : _submit,
                icon: _isSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: const Text('등록'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
