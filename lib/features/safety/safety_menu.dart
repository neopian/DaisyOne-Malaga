import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_repository.dart';
import '../questions/question_repository.dart';
import 'safety_repository.dart';

/// Available next to each piece of user content; no need to find a profile first.
class SafetyMenu extends ConsumerWidget {
  const SafetyMenu({
    super.key,
    required this.targetType,
    required this.targetId,
    required this.authorId,
    this.authorName = '작성자',
  });
  final String targetType;
  final String targetId;
  final String authorId;
  final String authorName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current =
        ref.watch(authStateProvider).asData?.value ??
        ref.read(authRepositoryProvider).currentUser;
    if (current == null || current.id == authorId || authorId.isEmpty) {
      return const SizedBox.shrink();
    }
    return PopupMenuButton<String>(
      tooltip: '신고 및 차단',
      icon: const Icon(Icons.more_horiz),
      onSelected: (value) async {
        if (value == 'report') {
          await showDialog<void>(
            context: context,
            builder: (_) =>
                ReportDialog(targetType: targetType, targetId: targetId),
          );
        } else {
          await showDialog<void>(
            context: context,
            builder: (_) => BlockUserDialog(userId: authorId, name: authorName),
          );
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'report', child: Text('이 콘텐츠 신고')),
        PopupMenuItem(value: 'block', child: Text('작성자 차단')),
      ],
    );
  }
}

class ReportDialog extends ConsumerStatefulWidget {
  const ReportDialog({
    super.key,
    required this.targetType,
    required this.targetId,
  });
  final String targetType;
  final String targetId;
  @override
  ConsumerState<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends ConsumerState<ReportDialog> {
  final _details = TextEditingController();
  String? _reason;
  String? _error;
  bool _sending = false;
  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending || _reason == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref
          .read(safetyRepositoryProvider)
          .report(
            targetType: widget.targetType,
            targetId: widget.targetId,
            reason: _reason!,
            details: _details.text,
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(const SnackBar(content: Text('신고를 접수했습니다.')));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_sending,
    child: AlertDialog(
      title: const Text('콘텐츠 신고'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('문제가 되는 이유를 알려주세요. 신고는 운영 검토에 사용됩니다.'),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _reason,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '신고 이유'),
              items: reportReasons.entries
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: _sending
                  ? null
                  : (value) => setState(() => _reason = value),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _details,
              enabled: !_sending,
              maxLength: 1000,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '추가 설명 (선택)',
                hintText: '불필요한 개인정보는 적지 마세요',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _sending || _reason == null ? null : _submit,
          child: Text(
            _sending
                ? '접수 중…'
                : _error == null
                ? '신고 접수'
                : '다시 접수',
          ),
        ),
      ],
    ),
  );
}

class BlockUserDialog extends ConsumerStatefulWidget {
  const BlockUserDialog({super.key, required this.userId, required this.name});
  final String userId;
  final String name;
  @override
  ConsumerState<BlockUserDialog> createState() => _BlockUserDialogState();
}

class _BlockUserDialogState extends ConsumerState<BlockUserDialog> {
  bool _sending = false;
  String? _error;
  Future<void> _block() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(safetyRepositoryProvider).block(widget.userId);
      if (!mounted) return;
      ref.invalidate(blockedUsersProvider);
      ref.invalidate(questionsProvider);
      ref.invalidate(questionProvider);
      ref.invalidate(helperOpenQuestionsProvider);
      final router = GoRouter.of(context);
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      router.go('/home');
      messenger.showSnackBar(
        const SnackBar(content: Text('사용자를 차단했습니다. 계정 설정에서 해제할 수 있습니다.')),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_sending,
    child: AlertDialog(
      title: Text('${widget.name} 차단'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '서로의 콘텐츠와 새로운 상호작용을 제한합니다. 이미 보관되거나 지급된 가상 포인트는 차단만으로 변경되지 않습니다. 차단은 계정 설정에서 해제할 수 있습니다.',
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _sending ? null : _block,
          child: Text(_sending ? '차단 중…' : '사용자 차단'),
        ),
      ],
    ),
  );
}
