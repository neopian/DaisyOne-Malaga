import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/app_constants.dart';
import '../../core/services/mvp_rules.dart';
import '../../shared/models/evidence_link.dart';
import '../../shared/widgets/app_page.dart';
import '../questions/question_repository.dart';
import 'answer_repository.dart';

class AnswerFormPage extends ConsumerStatefulWidget {
  const AnswerFormPage({super.key, required this.questionId});

  final String questionId;

  @override
  ConsumerState<AnswerFormPage> createState() => _AnswerFormPageState();
}

class _AnswerFormPageState extends ConsumerState<AnswerFormPage> {
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

  @override
  void dispose() {
    _body.dispose();
    _summary.dispose();
    _url.dispose();
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  void _addLink() {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null || !uri.hasScheme) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('근거 URL을 확인해주세요.')));
      return;
    }
    setState(() {
      _links.add(
        EvidenceLink(
          url: _url.text.trim(),
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
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_links.isEmpty && _url.text.trim().isNotEmpty) {
      _addLink();
    }
    if (!MvpRules.canSubmitAnswer(
      body: _body.text,
      evidenceUrls: _links.map((link) => link.url).toList(),
      confirmedEvidence: _confirmedEvidence,
      confirmedNoAiCopy: _confirmedNoAi,
      confirmedNoGuess: _confirmedNoGuess,
    )) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('답변 조건을 확인해주세요.')));
      return;
    }

    setState(() => _isSaving = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref
          .read(answerRepositoryProvider)
          .submitAnswer(
            questionId: widget.questionId,
            body: _body.text.trim(),
            evidenceSummary: _summary.text.trim(),
            verificationMethod: _method,
            links: _links,
          );
      ref.invalidate(questionProvider(widget.questionId));
      ref.invalidate(questionsProvider);
      ref.invalidate(helperOpenQuestionsProvider);
      if (mounted) router.go('/questions/${widget.questionId}');
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPage(
      title: '답변 작성',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _body,
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
                value: _method,
                decoration: const InputDecoration(labelText: '확인 방식'),
                items: AppConstants.verificationMethods
                    .map(
                      (value) =>
                          DropdownMenuItem(value: value, child: Text(value)),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _method = value!),
              ),
              const SizedBox(height: 20),
              Text('근거 사이트', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              TextFormField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _title,
                decoration: const InputDecoration(labelText: '근거 제목'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(labelText: '근거 메모'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _sourceType,
                decoration: const InputDecoration(labelText: '근거 유형'),
                items: AppConstants.sourceTypes.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _sourceType = value!),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _addLink,
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
                      onPressed: () => setState(() => _links.remove(link)),
                    ),
                  ),
              ],
              const Divider(height: 28),
              CheckboxListTile(
                value: _confirmedEvidence,
                onChanged: (value) =>
                    setState(() => _confirmedEvidence = value ?? false),
                title: const Text('확인 가능한 근거를 바탕으로 작성했습니다'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: _confirmedNoAi,
                onChanged: (value) =>
                    setState(() => _confirmedNoAi = value ?? false),
                title: const Text('AI가 생성한 내용을 그대로 제출하지 않았습니다'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: _confirmedNoGuess,
                onChanged: (value) =>
                    setState(() => _confirmedNoGuess = value ?? false),
                title: const Text('확실하지 않은 내용을 추측으로 작성하지 않았습니다'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _isSaving ? null : _submit,
                icon: _isSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: const Text('답변 제출'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
