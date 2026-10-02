import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/empty_state.dart';
import '../profile/profile_repository.dart';
import '../questions/question_repository.dart';
import '../safety/safety_repository.dart';

class AdminReportsPage extends ConsumerStatefulWidget {
  const AdminReportsPage({super.key});
  @override
  ConsumerState<AdminReportsPage> createState() => _AdminReportsPageState();
}

class _AdminReportsPageState extends ConsumerState<AdminReportsPage> {
  String _status = 'open';
  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(currentProfileProvider);
    return AppPage(
      title: '신고 검토',
      maxWidth: 840,
      body: AsyncValueView(
        value: profile,
        onRetry: () => ref.invalidate(currentProfileProvider),
        data: (user) => !user.isAdmin
            ? const Center(child: Text('관리자 권한이 필요합니다.'))
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('검토 대기'),
                          selected: _status == 'open',
                          onSelected: (_) => setState(() => _status = 'open'),
                        ),
                        ChoiceChip(
                          label: const Text('검토 완료'),
                          selected: _status == 'reviewed',
                          onSelected: (_) =>
                              setState(() => _status = 'reviewed'),
                        ),
                        IconButton(
                          tooltip: '신고 새로고침',
                          onPressed: () => ref.invalidate(
                            moderationReportsProvider(_status),
                          ),
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: AsyncValueView(
                      value: ref.watch(moderationReportsProvider(_status)),
                      onRetry: () =>
                          ref.invalidate(moderationReportsProvider(_status)),
                      data: (reports) => reports.isEmpty
                          ? const EmptyState(
                              icon: Icons.fact_check_outlined,
                              title: '표시할 신고가 없습니다',
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                              itemCount: reports.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (_, index) =>
                                  _ReportCard(report: reports[index]),
                            ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

const _actions = <String, String>{
  'dismiss': '조치 없이 검토 완료',
  'hide': '콘텐츠 숨기기',
  'restore': '콘텐츠 복원',
  'suspend': '작성자 이용 정지',
  'reinstate': '작성자 정지 해제',
};
const _targetTypes = {
  'question': '질문',
  'answer': '답변',
  'comment': '댓글',
  'user': '사용자',
};

class _ReportCard extends ConsumerWidget {
  const _ReportCard({required this.report});
  final Map<String, dynamic> report;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = report['target'] is Map
        ? Map<String, dynamic>.from(report['target'] as Map)
        : <String, dynamic>{};
    final type = report['target_type']?.toString() ?? '';
    final reason = reportReasons[report['reason']] ?? '기타';
    final details = report['details']?.toString() ?? '';
    final history = report['actions'] is List
        ? report['actions'] as List
        : const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${_targetTypes[type] ?? '콘텐츠'} · $reason',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (target['moderation_hidden'] == true)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('현재 숨겨진 콘텐츠'),
              ),
            const SizedBox(height: 12),
            if (target['title'] != null)
              Text(
                target['title'].toString(),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            if (target['name'] != null) Text(target['name'].toString()),
            if (target['body'] != null)
              SelectableText(target['body'].toString()),
            if (target['evidence_summary'] != null)
              Text('근거 요약: ${target['evidence_summary']}'),
            if (details.isNotEmpty) ...[
              const Divider(height: 28),
              Text('신고 설명', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              SelectableText(details),
            ],
            if (history.isNotEmpty) ...[
              const Divider(height: 28),
              Text('검토 기록', style: Theme.of(context).textTheme.labelLarge),
              for (final action in history.whereType<Map>())
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${_actions[action['action']] ?? action['action']}${action['note'] == null ? '' : ': ${action['note']}'}',
                  ),
                ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final action in _actions.entries)
                  if (type != 'user' ||
                      !['hide', 'restore'].contains(action.key))
                    OutlinedButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => _ReviewDialog(
                          reportId: report['id'].toString(),
                          action: action.key,
                        ),
                      ),
                      child: Text(action.value),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewDialog extends ConsumerStatefulWidget {
  const _ReviewDialog({required this.reportId, required this.action});
  final String reportId;
  final String action;
  @override
  ConsumerState<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends ConsumerState<_ReviewDialog> {
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _review() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(safetyRepositoryProvider)
          .review(
            reportId: widget.reportId,
            action: widget.action,
            note: _note.text,
          );
      if (!mounted) return;
      ref.invalidate(moderationReportsProvider);
      ref.invalidate(questionsProvider);
      ref.invalidate(questionProvider);
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(_actions[widget.action]!),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.action == 'suspend'
                  ? '작성자의 로그인을 종료하고 서비스 이용을 제한합니다. 이 조치는 보관·지급된 가상 포인트를 변경하지 않습니다.'
                  : '이 조치와 사유가 검토 기록에 남습니다. 보관·지급된 가상 포인트는 변경되지 않습니다.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _note,
              enabled: !_busy,
              minLines: 2,
              maxLines: 5,
              maxLength: 1000,
              decoration: const InputDecoration(labelText: '검토 사유 (선택)'),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _busy ? null : _review,
          child: Text(_busy ? '처리 중…' : '확인'),
        ),
      ],
    ),
  );
}
