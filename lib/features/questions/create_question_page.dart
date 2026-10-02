import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants/app_constants.dart';
import '../../core/geo/city_catalog.g.dart';
import '../../core/services/location_service.dart';
import '../../core/services/api_service.dart';
import '../../core/services/mvp_rules.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/app_page.dart';
import '../../shared/models/question.dart';
import '../activity/activity_repository.dart';
import '../auth/auth_repository.dart';
import '../profile/profile_repository.dart';
import 'question_repository.dart';
import 'travel_location_section.dart';
import 'travel_draft_store.dart';
import 'travel_question_support.dart';
import 'travel_recovery_questions.dart';

class CreateQuestionPage extends ConsumerStatefulWidget {
  const CreateQuestionPage({super.key});

  @override
  ConsumerState<CreateQuestionPage> createState() => _CreateQuestionPageState();
}

class _CreateQuestionPageState extends ConsumerState<CreateQuestionPage>
    with WidgetsBindingObserver {
  static const _locationUnavailableText = '질문할 도시를 목록에서 선택해주세요.';

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
  bool _isSaving = false;
  Future<String> Function()? _pendingCreate;
  TravelQuestionDraft? _pendingSnapshot;
  bool _hadUnknownSubmissionOutcome = false;
  bool _isResolvingLocation = false;
  String? _locationError;
  double? _latitude;
  double? _longitude;
  bool _isManualLocation = false;
  int _locationRevision = 0;
  int _draftRevision = 0;
  late final AuthRepository _auth;
  String? _draftOwnerId;
  String? _requestId;
  late final TravelDraftStore _draftStore;
  Timer? _draftSaveTimer;
  bool _isRestoringDraft = true;
  bool _draftReadFailed = false;
  bool _isRecoveredSubmission = false;
  int _unrestoredPhotoCount = 0;
  String? _draftNotice;
  String? _submissionError;
  int _saveRevision = 0;
  Future<List<Question>>? _recoveryQuestions;

  bool get _canEdit =>
      !_isSaving &&
      _pendingCreate == null &&
      !_isRestoringDraft &&
      !_draftReadFailed &&
      !_isRecoveredSubmission;

  DeviceLocation? get _selectedLocation => _hasRequiredLocation()
      ? DeviceLocation(
          country: _country.text,
          city: _city.text,
          regionName: _region.text,
          latitude: _latitude!,
          longitude: _longitude!,
        )
      : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _draftStore = ref.read(travelDraftStoreProvider);
    for (final controller in [_title, _body, _reward]) {
      controller.addListener(_scheduleDraftSave);
    }
    _auth = ref.read(authRepositoryProvider);
    _draftOwnerId = _auth.currentUser?.id;
    _auth.addListener(_handleAccountChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _restoreDraft();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draftSaveTimer?.cancel();
    if (_canEdit && _draftOwnerId != null) {
      // Snapshot synchronously before controllers are disposed.
      unawaited(
        _draftStore
            .save(_draftOwnerId!, _snapshotDraft())
            .catchError((Object _) {}),
      );
    }
    _auth.removeListener(_handleAccountChange);
    _title.dispose();
    _body.dispose();
    _country.dispose();
    _city.dispose();
    _region.dispose();
    _reward.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _canEdit) {
      _draftSaveTimer?.cancel();
      unawaited(_saveDraft());
    }
  }

  TravelQuestionDraft _snapshotDraft({bool? pending}) => TravelQuestionDraft(
    requestId: _requestId,
    title: _title.text,
    body: _body.text,
    category: _category,
    reward: _reward.text,
    country: _country.text,
    city: _city.text,
    region: _region.text,
    latitude: _latitude,
    longitude: _longitude,
    isManualLocation: _isManualLocation,
    imageCount: _images.length,
    submissionPending:
        pending ?? (_pendingCreate != null || _isRecoveredSubmission),
  );

  Future<void> _restoreDraft() async {
    final owner = _draftOwnerId;
    final revision = _draftRevision;
    if (owner == null) {
      if (mounted) setState(() => _isRestoringDraft = false);
      return;
    }
    try {
      final draft = await _draftStore.read(owner);
      if (!mounted || revision != _draftRevision) return;
      setState(() {
        if (draft != null) {
          _title.text = draft.title;
          _body.text = draft.body;
          _category = AppConstants.categories.contains(draft.category)
              ? draft.category
              : AppConstants.categories.first;
          _reward.text = draft.reward;
          _country.text = draft.country;
          _city.text = draft.city;
          _region.text = draft.region;
          _latitude = draft.latitude;
          _longitude = draft.longitude;
          _isManualLocation = draft.isManualLocation;
          _unrestoredPhotoCount = draft.imageCount;
          _requestId = draft.requestId;
          final reward = int.tryParse(draft.reward);
          final canRetry =
              draft.submissionPending &&
              draft.imageCount == 0 &&
              draft.requestId != null &&
              draft.requestId!.length >= 16 &&
              reward != null &&
              reward > 0 &&
              _hasRequiredLocation();
          _isRecoveredSubmission = draft.submissionPending && !canRetry;
          if (canRetry) {
            _pendingSnapshot = draft;
            _hadUnknownSubmissionOutcome = true;
            final repository = ref.read(questionRepositoryProvider);
            _pendingCreate = () => repository.createQuestion(
              requestId: draft.requestId,
              title: draft.title.trim(),
              body: draft.body.trim(),
              country: draft.country.trim(),
              city: draft.city.trim(),
              regionName: draft.region.trim().isEmpty
                  ? null
                  : draft.region.trim(),
              category: draft.category,
              urgency: AppConstants.defaultUrgency,
              rewardPoints: reward,
              latitude: draft.latitude!,
              longitude: draft.longitude!,
              images: const [],
            );
          }
          _draftNotice = draft.submissionPending
              ? canRetry
                    ? '중단된 요청을 불러왔어요. 같은 요청 다시 확인을 누르면 중복 등록 없이 결과를 확인합니다.'
                    : '이전 등록 요청의 결과를 확인해야 합니다.'
              : '이 계정의 임시 저장 글을 불러왔어요. 사진은 저장되지 않으니 다시 첨부해주세요.';
        }
        _isRestoringDraft = false;
      });
      if (draft == null) await _useCurrentLocation();
    } catch (_) {
      if (!mounted || revision != _draftRevision) return;
      setState(() {
        _isRestoringDraft = false;
        _draftReadFailed = true;
        _draftNotice = '임시 저장 글을 불러오지 못했어요. 이전 요청을 보호하기 위해 불러온 뒤 작성할 수 있어요.';
      });
    }
  }

  void _scheduleDraftSave() {
    if (!_canEdit || _draftOwnerId == null) return;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_saveDraft()),
    );
  }

  Future<bool> _saveDraft({bool? pending}) async {
    final owner = _draftOwnerId;
    if (owner == null) return false;
    final revision = _draftRevision;
    final saveRevision = ++_saveRevision;
    final snapshot = pending == true && _pendingSnapshot != null
        ? _pendingSnapshot!
        : _snapshotDraft(pending: pending);
    try {
      await _draftStore.save(owner, snapshot);
      if (mounted &&
          revision == _draftRevision &&
          saveRevision == _saveRevision) {
        setState(
          () => _draftNotice = snapshot.submissionPending
              ? '등록 요청 내용이 저장되어 있어요 · 사진 제외'
              : '아직 등록 전 · 이 기기에 글 임시 저장됨 · 사진 제외',
        );
      }
      return true;
    } catch (_) {
      if (mounted &&
          revision == _draftRevision &&
          saveRevision == _saveRevision) {
        setState(
          () => _draftNotice =
              '임시 저장 실패 · 이 화면을 닫으면 글이 사라질 수 있어요. 저장 공간을 확인해주세요.',
        );
      }
      return false;
    }
  }

  Future<void> _startNewAfterRecovery() async {
    final revision = _draftRevision;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이전 등록 여부를 확인했나요?'),
        content: const Text(
          '새로 작성해도 이전 요청은 취소되지 않습니다. 이미 등록되었다면 같은 질문이 다시 올라가고 포인트가 다시 보관될 수 있어요. 내 질문에서 확인한 뒤 진행해주세요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('유지하기'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('새 질문 작성'),
          ),
        ],
      ),
    );
    if (!mounted || approved != true || revision != _draftRevision) return;
    try {
      await _draftStore.clear(_draftOwnerId!);
    } catch (_) {
      if (mounted && revision == _draftRevision) {
        setState(() => _draftNotice = '이전 임시 저장을 지우지 못했어요. 저장 공간을 확인해주세요.');
      }
      return;
    }
    if (!mounted || revision != _draftRevision) return;
    setState(() {
      _isRestoringDraft = true;
      _title.clear();
      _body.clear();
      _images.clear();
      _reward.text = '100';
      _category = AppConstants.categories.first;
      _requestId = null;
      _recoveryQuestions = null;
      _pendingCreate = null;
      _pendingSnapshot = null;
      _hadUnknownSubmissionOutcome = false;
      _submissionError = null;
      _isRecoveredSubmission = false;
      _unrestoredPhotoCount = 0;
      _draftNotice = '새 질문을 작성할 수 있어요.';
      _isRestoringDraft = false;
    });
  }

  void _handleAccountChange() {
    final owner = _auth.currentUser?.id;
    if (owner == _draftOwnerId || !mounted) return;
    // No draft text, picked photo, delayed GPS result, or pending request from
    // the previous account may be carried into the next account's form.
    _draftSaveTimer?.cancel();
    if (_canEdit && _draftOwnerId != null) {
      unawaited(
        _draftStore
            .save(_draftOwnerId!, _snapshotDraft())
            .catchError((Object _) {}),
      );
    }
    setState(() {
      _requestId = null;
      _recoveryQuestions = null;
      _draftReadFailed = false;
      _isRestoringDraft = true;
      _isRecoveredSubmission = false;
      _unrestoredPhotoCount = 0;
      _draftNotice = null;
      _submissionError = null;
      _draftOwnerId = owner;
      _draftRevision++;
      _locationRevision++;
      _pendingCreate = null;
      _pendingSnapshot = null;
      _hadUnknownSubmissionOutcome = false;
      _isSaving = false;
      _isResolvingLocation = false;
      _title.clear();
      _body.clear();
      _country.clear();
      _city.clear();
      _region.clear();
      _reward.text = '100';
      _images.clear();
      _category = AppConstants.categories.first;
      _latitude = null;
      _longitude = null;
      _isManualLocation = false;
      _locationError = null;
    });
    unawaited(_restoreDraft());
  }

  Future<void> _pickImage() async {
    if (!_canEdit) return;
    final revision = _draftRevision;
    final picked = await _picker.pickMultiImage(
      limit: 5,
      requestFullMetadata: false,
    );
    if (!mounted || revision != _draftRevision || !_canEdit || picked.isEmpty) {
      return;
    }
    setState(() {
      _images
        ..clear()
        ..addAll(picked.take(5));
      _unrestoredPhotoCount = 0;
    });
    _scheduleDraftSave();
  }

  void _selectCity(TravelCity place) {
    if (!_canEdit) return;
    final location = locationForTravelCity(place);
    setState(() {
      _locationRevision++;
      _isResolvingLocation = false;
      _isManualLocation = true;
      _locationError = null;
      _setLocation(location);
    });
    _scheduleDraftSave();
  }

  void _setLocation(DeviceLocation location) {
    _country.text = location.country;
    _city.text = location.city;
    _region.text = location.regionName ?? '';
    _latitude = location.latitude;
    _longitude = location.longitude;
  }

  Future<void> _useCurrentLocation() async {
    if (_isResolvingLocation || !_canEdit) return;
    final revision = ++_locationRevision;
    setState(() {
      _isResolvingLocation = true;
      _locationError = null;
    });
    try {
      final location = await ref.read(questionLocationLoaderProvider)();
      if (!mounted || revision != _locationRevision || !_canEdit) return;
      if (!CityCatalog.isSupportedLocation(location.country, location.city) ||
          !location.latitude.isFinite ||
          !location.longitude.isFinite ||
          location.latitude.abs() > 90 ||
          location.longitude.abs() > 180) {
        throw StateError('선택 가능한 도시에서 멀리 떨어져 있습니다.');
      }
      setState(() {
        _setLocation(location);
        _isManualLocation = false;
      });
      _scheduleDraftSave();
    } catch (error) {
      if (!mounted || revision != _locationRevision || !_canEdit) return;
      // Failed GPS retries must not erase a valid manually chosen city.
      setState(() => _locationError = travelLocationError(error));
    } finally {
      if (mounted && revision == _locationRevision) {
        setState(() => _isResolvingLocation = false);
      }
    }
  }

  Future<void> _applyStarter(TravelQuestionStarter starter) async {
    if (!_canEdit) return;
    final revision = _draftRevision;
    if (_title.text.isNotEmpty || _body.text.isNotEmpty) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('작성한 내용을 바꿀까요?'),
          content: SingleChildScrollView(
            child: Text(
              '현재 제목과 내용을 “${starter.label}” 예시로 바꿉니다. 취소하면 작성한 내용이 그대로 유지됩니다.\n\n${starter.title}\n\n${starter.body}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('유지하기'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('예시로 바꾸기'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    if (!mounted || revision != _draftRevision || !_canEdit) return;
    setState(() {
      _title.text = starter.title;
      _body.text = starter.body;
      _category = starter.category;
    });
  }

  bool _hasRequiredLocation() {
    final latitude = _latitude;
    final longitude = _longitude;
    return CityCatalog.isSupportedLocation(_country.text, _city.text) &&
        latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite &&
        latitude.abs() <= 90 &&
        longitude.abs() <= 180;
  }

  Future<void> _submit() async {
    if (_isSaving ||
        _isRestoringDraft ||
        _draftReadFailed ||
        _isRecoveredSubmission) {
      return;
    }
    if (_draftOwnerId == null || _auth.currentUser?.id != _draftOwnerId) return;
    if (_pendingCreate != null) {
      await _sendPendingQuestion();
      return;
    }
    if (!_hasRequiredLocation()) {
      setState(() => _locationError = _locationUnavailableText);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(_locationUnavailableText)));
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null || profile.id != _draftOwnerId) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('프로필을 불러온 뒤 다시 시도해주세요.')));
      return;
    }
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

    final repository = ref.read(questionRepositoryProvider);
    final coordinates = _coordinatesForSubmit();
    final title = _title.text.trim();
    final body = _body.text.trim();
    final country = _country.text.trim();
    final city = _city.text.trim();
    final region = _region.text.trim().isEmpty ? null : _region.text.trim();
    final category = _category;
    final images = List<XFile>.of(_images);
    final random = Random.secure();
    final requestId = base64UrlEncode(
      List<int>.generate(24, (_) => random.nextInt(256)),
    );
    _requestId = requestId;
    _hadUnknownSubmissionOutcome = false;
    _pendingSnapshot = _snapshotDraft(pending: true);
    _pendingCreate = () => repository.createQuestion(
      requestId: requestId,
      title: title,
      body: body,
      country: country,
      city: city,
      regionName: region,
      category: category,
      urgency: AppConstants.defaultUrgency,
      rewardPoints: rewardPoints,
      latitude: coordinates.latitude,
      longitude: coordinates.longitude,
      images: images,
    );
    await _sendPendingQuestion();
  }

  Future<void> _sendPendingQuestion() async {
    final pending = _pendingCreate;
    final revision = _draftRevision;
    if (pending == null || _draftOwnerId != _auth.currentUser?.id) return;
    _draftSaveTimer?.cancel();
    _locationRevision++;
    setState(() {
      _isSaving = true;
      _submissionError = null;
      _isResolvingLocation = false;
    });
    if (!await _saveDraft(pending: true)) {
      if (mounted && revision == _draftRevision) {
        setState(() {
          _isSaving = false;
          _submissionError = '임시 저장 공간을 확인한 뒤 같은 요청으로 다시 시도해주세요.';
        });
      }
      return;
    }
    if (!mounted || revision != _draftRevision) return;
    final router = GoRouter.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final id = await pending();
      if (!mounted || revision != _draftRevision) return;
      _pendingCreate = null;
      try {
        await _draftStore.clear(_draftOwnerId!);
      } catch (_) {
        // A retained text snapshot keeps its explicit operation ID, so a
        // later manual retry still replays this result. Photo drafts stay locked.
      }
      if (!mounted || revision != _draftRevision) return;
      _isRecoveredSubmission =
          true; // Do not autosave completed text on dispose.
      container.invalidate(questionsProvider);
      container.invalidate(helperOpenQuestionsProvider);
      container.invalidate(pointTransactionsProvider);
      container.invalidate(currentProfileProvider);
      if (mounted) router.go('/questions/$id');
    } catch (error) {
      if (!mounted || revision != _draftRevision) return;
      // A retry can reach authentication/rate limits/storage/response parsing
      // after a previous attempt already committed. Only definitive validation
      // rejections release the immutable payload and its operation ID.
      final definitiveRejection =
          !_hadUnknownSubmissionOutcome &&
          error is ApiException &&
          (error.code == 'invalid_image' ||
              (error.status != null &&
                  error.status! >= 400 &&
                  error.status! < 500 &&
                  !const [401, 408, 409, 429].contains(error.status)));
      if (definitiveRejection) {
        _pendingCreate = null;
        _pendingSnapshot = null;
        _requestId = null;
        await _saveDraft(pending: false);
      } else {
        _hadUnknownSubmissionOutcome = true;
      }
      if (!mounted || revision != _draftRevision) return;
      setState(() => _submissionError = error.toString());
    } finally {
      if (mounted && revision == _draftRevision) {
        setState(() => _isSaving = false);
      }
    }
  }

  ({double latitude, double longitude}) _coordinatesForSubmit() {
    final latitude = _latitude;
    final longitude = _longitude;
    if (latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite &&
        latitude.abs() <= 90 &&
        longitude.abs() <= 180) {
      return (latitude: latitude, longitude: longitude);
    }
    throw StateError(_locationUnavailableText);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final profile = ref.watch(currentProfileProvider).asData?.value;
    return AppPage(
      title: '질문 등록',
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Center(
          child: ConstrainedBox(
            key: const ValueKey('question-form-content'),
            constraints: const BoxConstraints(maxWidth: 680),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '무엇이 궁금한가요?',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '장소와 상황을 적어 여행 질문을 시작해보세요.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_isRestoringDraft || _draftNotice != null) ...[
                    _QuestionNotice(
                      icon: _isRestoringDraft
                          ? Icons.hourglass_top_rounded
                          : _draftReadFailed
                          ? Icons.info_outline_rounded
                          : Icons.save_outlined,
                      isError: _draftReadFailed,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_isRestoringDraft)
                            const Text('이 계정의 임시 저장 글 확인 중…'),
                          if (_draftNotice != null)
                            Text(
                              _draftNotice!,
                              key: const ValueKey('question-draft-status'),
                            ),
                          if (_draftReadFailed) ...[
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: () {
                                setState(() {
                                  _isRestoringDraft = true;
                                  _draftReadFailed = false;
                                  _draftNotice = null;
                                });
                                unawaited(_restoreDraft());
                              },
                              child: const Text('임시 저장 다시 확인'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_isRecoveredSubmission) ...[
                    _QuestionSection(
                      key: const ValueKey('question-recovery-section'),
                      title: '이전 질문을 먼저 확인해주세요',
                      children: [
                        const Text(
                          '등록 중 연결이나 앱이 끊겼습니다. 이미 등록되었을 수 있으니 내 질문에서 먼저 확인해주세요. 이 화면에서는 자동으로 다시 보내지 않습니다.',
                        ),
                        if (_unrestoredPhotoCount > 0) ...[
                          const SizedBox(height: 8),
                          Text(
                            '이전 요청에 사진 $_unrestoredPhotoCount장이 있었습니다. 사진은 이 기기에 임시 저장되지 않습니다.',
                          ),
                        ],
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => setState(() {
                            _recoveryQuestions = ref
                                .read(activityRepositoryProvider)
                                .fetchRecentOwnQuestions();
                          }),
                          child: Text(
                            _recoveryQuestions == null
                                ? '내 질문에서 등록 여부 확인'
                                : '최근 내 질문 다시 확인',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        if (_recoveryQuestions != null) ...[
                          const SizedBox(height: 16),
                          TravelRecoveryQuestions(
                            questions: _recoveryQuestions!,
                            ownerId: _draftOwnerId!,
                            onOpen: (question) =>
                                context.go('/questions/${question.id}'),
                          ),
                        ],
                        TextButton(
                          onPressed: _startNewAfterRecovery,
                          child: const Text(
                            '이전 요청을 확인했고 새로 작성',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                  _QuestionSection(
                    key: const ValueKey('question-content-section'),
                    title: '질문',
                    children: [
                      TextFormField(
                        key: const ValueKey('question-title'),
                        enabled: _canEdit,
                        controller: _title,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '질문 제목',
                          hintText: '어떤 도움이 필요한가요?',
                          errorMaxLines: 3,
                        ),
                        validator: (value) =>
                            value == null || value.trim().length < 4
                            ? '제목을 입력해주세요.'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const ValueKey('question-body'),
                        enabled: _canEdit,
                        controller: _body,
                        minLines: 4,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          labelText: '질문 내용',
                          hintText: '장소, 날짜와 현지 시각을 함께 알려주세요.',
                          alignLabelWithHint: true,
                          errorMaxLines: 3,
                        ),
                        validator: (value) =>
                            value == null || value.trim().length < 10
                            ? '상황을 조금 더 적어주세요.'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _canEdit ? _pickImage : null,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: Text(
                          _images.isEmpty
                              ? '사진 첨부'
                              : '사진 ${_images.length}장 선택됨',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'JPG·PNG·WebP 정지 사진 · 최대 5장\n장당 3MiB·2,000만 화소 이하',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Theme(
                        data: theme.copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          key: const ValueKey('question-starters'),
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(bottom: 8),
                          title: Text(
                            '여행 질문 빠르게 시작하기',
                            style: theme.textTheme.titleSmall,
                          ),
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  for (final starter in travelQuestionStarters)
                                    ActionChip(
                                      label: Text(starter.label),
                                      onPressed: _canEdit
                                          ? () => _applyStarter(starter)
                                          : null,
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '예시를 고른 뒤 장소와 날짜·현지 시각을 채워주세요. 실시간 정보나 답변 도착을 보장하지는 않아요.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TravelLocationSection(
                    key: ValueKey('travel-location-$_draftRevision'),
                    location: _selectedLocation,
                    isManual: _isManualLocation,
                    isLoading: _isResolvingLocation,
                    enabled: _canEdit,
                    errorText: _locationError,
                    onCitySelected: _selectCity,
                    onUseCurrentLocation: _useCurrentLocation,
                  ),
                  const SizedBox(height: 16),
                  _QuestionSection(
                    key: const ValueKey('question-reward-section'),
                    title: '카테고리와 보상',
                    children: [
                      DropdownButtonFormField<String>(
                        key: ValueKey('question-category-$_category'),
                        initialValue: _category,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '카테고리'),
                        items: AppConstants.categories
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: !_canEdit
                            ? null
                            : (value) {
                                setState(() => _category = value!);
                                _scheduleDraftSave();
                              },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const ValueKey('question-reward'),
                        enabled: _canEdit,
                        controller: _reward,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '보상 포인트',
                          helperText: '가상 포인트이며 현금 가치·구매·출금 기능은 없습니다.',
                          helperMaxLines: 4,
                          errorMaxLines: 3,
                          suffixText: 'P',
                        ),
                        validator: (value) {
                          final points = int.tryParse(value ?? '');
                          if (points == null || points <= 0) {
                            return '1 이상 입력해주세요.';
                          }
                          return null;
                        },
                      ),
                      if (profile != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          '잔액 ${formatPoints(profile.pointBalance)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_submissionError != null ||
                      (_pendingCreate != null && !_isSaving)) ...[
                    _QuestionNotice(
                      icon: Icons.info_outline_rounded,
                      isError: _submissionError != null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_submissionError != null) Text(_submissionError!),
                          if (_pendingCreate != null && !_isSaving) ...[
                            if (_submissionError != null)
                              const SizedBox(height: 8),
                            const Text(
                              '처리 결과를 확인하지 못했습니다. 중복 차감을 막기 위해 같은 내용으로 다시 확인합니다.',
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (!_isRecoveredSubmission)
                    FilledButton.icon(
                      key: const ValueKey('question-submit'),
                      onPressed:
                          _isSaving || _isRestoringDraft || _draftReadFailed
                          ? null
                          : _submit,
                      icon: _isSaving
                          ? SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: scheme.onSurfaceVariant,
                              ),
                            )
                          : Icon(
                              _pendingCreate != null
                                  ? Icons.refresh_rounded
                                  : Icons.arrow_upward_rounded,
                            ),
                      label: Text(
                        _isSaving
                            ? '등록 결과 확인 중…'
                            : _pendingCreate != null
                            ? '같은 요청 다시 확인'
                            : '질문 등록',
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuestionSection extends StatelessWidget {
  const _QuestionSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 20),
          ...children,
        ],
      ),
    ),
  );
}

class _QuestionNotice extends StatelessWidget {
  const _QuestionNotice({
    required this.icon,
    required this.child,
    this.isError = false,
  });

  final IconData icon;
  final Widget child;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = isError ? scheme.error : scheme.onSurfaceVariant;
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isError
              ? scheme.errorContainer.withValues(alpha: 0.4)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icon, size: 20, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DefaultTextStyle.merge(
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
