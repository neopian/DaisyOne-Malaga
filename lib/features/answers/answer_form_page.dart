import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/app_constants.dart';
import '../../core/services/mvp_rules.dart';
import '../../core/services/api_service.dart';
import '../../shared/models/evidence_link.dart';
import '../../shared/widgets/app_page.dart';
import '../questions/question_repository.dart';
import '../auth/auth_repository.dart';
import 'answer_draft_store.dart';
import 'answer_repository.dart';

class AnswerFormPage extends ConsumerStatefulWidget {
  const AnswerFormPage({super.key, required this.questionId});

  final String questionId;

  @override
  ConsumerState<AnswerFormPage> createState() => _AnswerFormPageState();
}

class _AnswerFormPageState extends ConsumerState<AnswerFormPage>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _body = TextEditingController();
  final _summary = TextEditingController();
  final _url = TextEditingController();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _links = <EvidenceLink>[];
  String _method = AppConstants.verificationMethods.first;
  String _sourceType = AppConstants.sourceTypes.keys.first;
  bool _confirmedEvidence = false;
  bool _confirmedNoAi = false;
  bool _confirmedNoGuess = false;
  bool _isSaving = false;

  late final AnswerDraftStore _drafts;
  late final AuthRepository _auth;
  late String _questionId;
  String? _owner;
  AnswerSubmission? _pending;
  bool _restoring = true;
  bool _readFailed = false;
  bool _completed = false;
  bool _unknownOutcome = false;
  String? _notice;
  String? _error;
  String? _storageError;
  int _revision = 0;
  int _saveRevision = 0;
  Timer? _saveTimer;

  bool get _canEdit =>
      !_isSaving &&
      !_restoring &&
      !_readFailed &&
      !_completed &&
      _pending == null &&
      _owner != null;

  @override
  void initState() {
    super.initState();
    _questionId = widget.questionId;
    _drafts = ref.read(answerDraftStoreProvider);
    _auth = ref.read(authRepositoryProvider);
    _owner = _auth.currentUser?.id;
    _auth.addListener(_accountChanged);
    WidgetsBinding.instance.addObserver(this);
    for (final controller in [_body, _summary, _url, _title, _description]) {
      controller.addListener(_scheduleSave);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _restore();
    });
  }

  @override
  void didUpdateWidget(covariant AnswerFormPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.questionId != _questionId) {
      _changeScope(_auth.currentUser?.id, widget.questionId);
    }
  }

  void _accountChanged() {
    if (_owner != _auth.currentUser?.id) {
      _changeScope(_auth.currentUser?.id, widget.questionId);
    }
  }

  void _changeScope(String? owner, String question) {
    _saveTimer?.cancel();
    if (_canEdit) {
      unawaited(_drafts.save(_owner!, _snapshot()).catchError((Object _) {}));
    }
    _revision++;
    setState(() {
      _restoring = true;
      _readFailed = false;
      _isSaving = false;
      _completed = false;
      _pending = null;
      _unknownOutcome = false;
      _owner = owner;
      _questionId = question;
      _notice = null;
      _error = null;
      _storageError = null;
      _body.clear();
      _summary.clear();
      _url.clear();
      _title.clear();
      _description.clear();
      _links.clear();
      _confirmedEvidence = false;
      _confirmedNoAi = false;
      _confirmedNoGuess = false;
      _method = AppConstants.verificationMethods.first;
      _sourceType = AppConstants.sourceTypes.keys.first;
    });
    unawaited(_restore());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_canEdit) {
      unawaited(_drafts.save(_owner!, _snapshot()).catchError((Object _) {}));
    }
    _auth.removeListener(_accountChanged);
    WidgetsBinding.instance.removeObserver(this);
    _body.dispose();
    _summary.dispose();
    _url.dispose();
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _canEdit) {
      _saveTimer?.cancel();
      unawaited(_saveDraft());
    }
  }

  AnswerDraft _snapshot({bool includePending = true}) => AnswerDraft(
    questionId: _questionId,
    body: _body.text,
    evidenceSummary: _summary.text,
    verificationMethod: _method,
    linkUrl: _url.text,
    linkTitle: _title.text,
    linkDescription: _description.text,
    sourceType: _sourceType,
    links: _links,
    pending: includePending ? _pending : null,
  );

  Future<void> _restore() async {
    final owner = _owner;
    final revision = _revision;
    if (owner == null) {
      setState(() => _restoring = false);
      return;
    }
    setState(() {
      _restoring = true;
      _readFailed = false;
      _error = null;
    });
    try {
      final draft = await _drafts.read(owner, _questionId);
      if (!mounted || revision != _revision) return;
      setState(() {
        if (draft != null) {
          final pending = draft.pending;
          _body.text = pending?.body ?? draft.body;
          _summary.text = pending?.evidenceSummary ?? draft.evidenceSummary;
          final method =
              pending?.verificationMethod ?? draft.verificationMethod;
          if (!AppConstants.verificationMethods.contains(method)) {
            throw const FormatException('Unknown verification method');
          }
          _method = method;
          _url.text = draft.linkUrl;
          _title.text = draft.linkTitle;
          _description.text = draft.linkDescription;
          _sourceType = AppConstants.sourceTypes.containsKey(draft.sourceType)
              ? draft.sourceType
              : AppConstants.sourceTypes.keys.first;
          _links
            ..clear()
            ..addAll(pending?.links ?? draft.links);
          _pending = pending;
          _unknownOutcome = pending != null;
          // Only a persisted, already-confirmed immutable request restores checks.
          _confirmedEvidence = pending?.confirmedEvidence ?? false;
          _confirmedNoAi = pending?.confirmedNoAi ?? false;
          _confirmedNoGuess = pending?.confirmedNoGuess ?? false;
          _notice = pending == null
              ? '이 질문의 임시 저장 답변을 불러왔어요. 내용을 확인한 뒤 제출 확인 항목을 다시 선택해주세요.'
              : '제출 결과를 확인하지 못한 답변을 불러왔어요. 중복 제출을 막기 위해 같은 내용과 요청 번호로 다시 확인합니다.';
        }
        _restoring = false;
      });
    } catch (_) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _restoring = false;
        _readFailed = true;
        _error = '임시 저장 답변을 불러오지 못했어요. 이전 요청을 보호하기 위해 내용을 불러온 뒤 작성할 수 있습니다.';
      });
    }
  }

  void _scheduleSave() {
    if (!_canEdit) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_saveDraft()),
    );
  }

  Future<bool> _saveDraft() async {
    if (_owner == null) return false;
    final owner = _owner!;
    final revision = _revision;
    final saveRevision = ++_saveRevision;
    final draft = _snapshot();
    try {
      await _drafts.save(owner, draft);
      if (mounted && revision == _revision && saveRevision == _saveRevision) {
        setState(() {
          _storageError = null;
          _notice = draft.pending == null
              ? '이 기기에 답변 임시 저장됨 · 아직 제출 전'
              : '제출 요청 내용이 이 기기에 저장되어 있습니다.';
        });
      }
      return true;
    } catch (_) {
      if (mounted && revision == _revision && saveRevision == _saveRevision) {
        setState(
          () => _storageError =
              '임시 저장 실패 · 저장 공간을 확인해주세요. 이 화면을 닫으면 최근 내용이 사라질 수 있습니다.',
        );
      }
      return false;
    }
  }

  Future<void> _discardUnreadable() async {
    final revision = _revision;
    final owner = _owner;
    if (owner == null || _isSaving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('이 질문의 임시 저장을 지울까요?'),
        content: const Text(
          '저장된 내용을 복구할 수 없게 됩니다. 이전 요청은 취소되지 않습니다. 질문 화면에서 이미 답변이 제출되었는지 확인한 뒤 진행해주세요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('유지하기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('임시 저장 삭제'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || revision != _revision) return;
    setState(() => _isSaving = true);
    try {
      await _drafts.clear(owner, _questionId);
      if (mounted && revision == _revision) _changeScope(owner, _questionId);
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() {
          _isSaving = false;
          _error = '임시 저장을 지우지 못했어요. 저장 공간을 확인한 뒤 다시 시도해주세요.';
        });
      }
    }
  }

  bool _addLink() {
    if (!_canEdit) return false;
    if (_links.length >= 10) {
      setState(() => _error = '근거는 최대 10개까지 추가할 수 있습니다.');
      return false;
    }
    if (!MvpRules.isValidEvidenceUrl(_url.text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('공백이나 로그인 정보가 없는 http 또는 https 근거 URL을 입력해주세요.'),
        ),
      );
      return false;
    }
    setState(() {
      _links.add(
        EvidenceLink(
          url: _url.text,
          title: _title.text.trim().isEmpty ? null : _title.text.trim(),
          description: _description.text.trim().isEmpty
              ? null
              : _description.text.trim(),
          sourceType: _sourceType,
        ),
      );
      _url.clear();
      _title.clear();
      _description.clear();
      _sourceType = AppConstants.sourceTypes.keys.first;
    });
    _scheduleSave();
    return true;
  }

  Future<void> _submit() async {
    if (_isSaving ||
        _restoring ||
        _readFailed ||
        _completed ||
        _owner == null ||
        _owner != _auth.currentUser?.id) {
      return;
    }
    if (_pending == null) {
      if (!_formKey.currentState!.validate()) return;
      if (_url.text.isNotEmpty && !_addLink()) return;
      if (!MvpRules.canSubmitAnswer(
        body: _body.text,
        evidenceUrls: _links.map((link) => link.url).toList(),
        confirmedEvidence: _confirmedEvidence,
        confirmedNoAiCopy: _confirmedNoAi,
        confirmedNoGuess: _confirmedNoGuess,
      )) {
        setState(() => _error = '답변 조건과 세 가지 확인 항목을 확인해주세요.');
        return;
      }
      final random = Random.secure();
      _pending = AnswerSubmission(
        requestId: base64UrlEncode(
          List<int>.generate(24, (_) => random.nextInt(256)),
        ),
        body: _body.text.trim(),
        evidenceSummary: _summary.text.trim(),
        verificationMethod: _method,
        links: _links,
        confirmedEvidence: _confirmedEvidence,
        confirmedNoAi: _confirmedNoAi,
        confirmedNoGuess: _confirmedNoGuess,
      );
      _unknownOutcome = false;
    }
    final pending = _pending!;
    final owner = _owner!;
    final question = _questionId;
    final revision = _revision;
    final unknownBefore = _unknownOutcome;
    final unsent = _snapshot(includePending: false);
    final repository = ref.read(answerRepositoryProvider);
    final router = GoRouter.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    _saveTimer?.cancel();
    setState(() {
      _isSaving = true;
      _error = null;
    });
    if (!await _saveDraft()) {
      if (mounted && revision == _revision) setState(() => _isSaving = false);
      return;
    }
    if (!mounted || revision != _revision) return;
    try {
      await repository.submitAnswer(
        questionId: question,
        body: pending.body,
        evidenceSummary: pending.evidenceSummary,
        verificationMethod: pending.verificationMethod,
        links: pending.links,
        requestId: pending.requestId,
      );
      var removed = true;
      try {
        await _drafts.completeAttempt(owner, question, pending.requestId);
      } catch (_) {
        removed = false;
      }
      if (!mounted || revision != _revision) return;
      setState(() {
        _completed = true;
        _pending = null;
        _isSaving = false;
      });
      container.invalidate(questionProvider(question));
      container.invalidate(questionsProvider);
      container.invalidate(helperOpenQuestionsProvider);
      if (!removed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '답변은 제출되었습니다. 이 기기의 임시 저장 정리는 완료하지 못했습니다. 다시 열어도 같은 요청으로 확인합니다.',
            ),
          ),
        );
      }
      router.go('/questions/${Uri.encodeComponent(question)}');
    } catch (error) {
      final definitive =
          !unknownBefore &&
          error is ApiException &&
          error.status != null &&
          error.status! >= 400 &&
          error.status! < 500 &&
          !const [401, 408, 409, 429].contains(error.status);
      var released = true;
      if (definitive) {
        try {
          await _drafts.releaseAttempt(owner, unsent, pending.requestId);
        } catch (_) {
          released = false;
        }
      }
      if (!mounted || revision != _revision) return;
      setState(() {
        _isSaving = false;
        _error = error.toString();
        if (definitive) {
          _pending = null;
          _storageError = released
              ? null
              : '요청은 거절되었지만 임시 저장 상태를 갱신하지 못했습니다. 화면을 닫기 전에 임시 저장을 다시 시도해주세요.';
          _confirmedEvidence = false;
          _confirmedNoAi = false;
          _confirmedNoGuess = false;
          _notice = '요청이 거절되었습니다. 내용을 수정한 뒤 확인 항목을 다시 선택해주세요.';
        } else {
          _unknownOutcome = true;
          _notice = '제출 결과가 아직 확인되지 않았습니다. 내용을 바꾸지 않고 같은 요청으로 다시 확인해주세요.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPage(
      maxWidth: 760,
      title: '답변 작성',
      actions: [
        IconButton(
          tooltip: '질문으로 돌아가기',
          onPressed: () =>
              context.go('/questions/${Uri.encodeComponent(_questionId)}'),
          icon: const Icon(Icons.close),
        ),
      ],
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_restoring)
                const LinearProgressIndicator(
                  semanticsLabel: '답변 임시 저장 불러오는 중',
                ),
              if (_notice != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _notice!,
                    key: const ValueKey('answer-draft-status'),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_error != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_readFailed) ...[
                OutlinedButton(
                  onPressed: _isSaving ? null : _restore,
                  child: const Text('임시 저장 다시 불러오기'),
                ),
                TextButton(
                  onPressed: _isSaving ? null : _discardUnreadable,
                  child: const Text('이 질문의 임시 저장 삭제'),
                ),
              ],
              if (_pending != null || _readFailed)
                TextButton(
                  onPressed: () => context.go(
                    '/questions/${Uri.encodeComponent(_questionId)}',
                  ),
                  child: const Text('질문에서 이전 답변 확인'),
                ),
              if (_storageError != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _storageError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_canEdit && _storageError != null)
                TextButton(
                  onPressed: _saveDraft,
                  child: const Text('임시 저장 다시 시도'),
                ),
              TextFormField(
                controller: _body,
                readOnly: !_canEdit,
                maxLength: 10000,
                minLines: 5,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: '답변 본문',
                  alignLabelWithHint: true,
                ),
                validator: (value) => value == null || value.trim().length < 10
                    ? '답변을 입력해주세요.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _summary,
                readOnly: !_canEdit,
                maxLength: 3000,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '근거 설명',
                  alignLabelWithHint: true,
                ),
                validator: (value) => value == null || value.trim().length < 6
                    ? '근거 설명을 입력해주세요.'
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('method-$_revision-$_restoring'),
                initialValue: _method,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '확인 방식'),
                items: AppConstants.verificationMethods
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(
                          value,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: !_canEdit
                    ? null
                    : (value) {
                        setState(() => _method = value!);
                        _scheduleSave();
                      },
              ),
              const SizedBox(height: 20),
              Text('근거 사이트', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              TextFormField(
                controller: _url,
                readOnly: !_canEdit,
                maxLength: 2048,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _title,
                readOnly: !_canEdit,
                maxLength: 300,
                decoration: const InputDecoration(labelText: '근거 제목'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _description,
                readOnly: !_canEdit,
                maxLength: 2000,
                decoration: const InputDecoration(labelText: '근거 메모'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: ValueKey('source-$_revision-$_restoring'),
                initialValue: _sourceType,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '근거 유형'),
                items: AppConstants.sourceTypes.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(
                          entry.value,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: !_canEdit
                    ? null
                    : (value) {
                        setState(() => _sourceType = value!);
                        _scheduleSave();
                      },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: !_canEdit ? null : _addLink,
                icon: const Icon(Icons.add_link),
                label: const Text('근거 추가'),
              ),
              if (_links.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final link in _links)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.link),
                    title: Text(link.title ?? link.url),
                    subtitle: Text(link.url),
                    trailing: IconButton(
                      tooltip: '삭제',
                      icon: const Icon(Icons.close),
                      onPressed: !_canEdit
                          ? null
                          : () {
                              setState(() => _links.remove(link));
                              _scheduleSave();
                            },
                    ),
                  ),
              ],
              const Divider(height: 28),
              CheckboxListTile(
                value: _confirmedEvidence,
                onChanged: !_canEdit
                    ? null
                    : (value) =>
                          setState(() => _confirmedEvidence = value ?? false),
                title: const Text('확인 가능한 근거를 바탕으로 작성했습니다'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: _confirmedNoAi,
                onChanged: !_canEdit
                    ? null
                    : (value) =>
                          setState(() => _confirmedNoAi = value ?? false),
                title: const Text('AI가 생성한 내용을 그대로 제출하지 않았습니다'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: _confirmedNoGuess,
                onChanged: !_canEdit
                    ? null
                    : (value) =>
                          setState(() => _confirmedNoGuess = value ?? false),
                title: const Text('확실하지 않은 내용을 추측으로 작성하지 않았습니다'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed:
                    _isSaving ||
                        _restoring ||
                        _readFailed ||
                        _completed ||
                        _owner == null
                    ? null
                    : _submit,
                icon: _isSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(
                  _isSaving
                      ? '요청 확인 중'
                      : _pending != null
                      ? '같은 요청 다시 확인'
                      : '답변 제출',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
