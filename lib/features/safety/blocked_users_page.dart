import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/empty_state.dart';
import '../questions/question_repository.dart';
import 'safety_repository.dart';

class BlockedUsersPage extends ConsumerWidget {
  const BlockedUsersPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => AppPage(
    title: '차단한 사용자',
    maxWidth: 720,
    body: AsyncValueView(
      value: ref.watch(blockedUsersProvider),
      onRetry: () => ref.invalidate(blockedUsersProvider),
      data: (users) => users.isEmpty
          ? const Center(
              child: EmptyState(
                icon: Icons.person_off_outlined,
                title: '차단한 사용자가 없습니다',
                subtitle: '콘텐츠 옆 더 보기에서 신고하거나 작성자를 차단할 수 있습니다.',
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: users.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, index) => _BlockedUserCard(user: users[index]),
            ),
    ),
  );
}

class _BlockedUserCard extends ConsumerStatefulWidget {
  const _BlockedUserCard({required this.user});
  final BlockedUser user;
  @override
  ConsumerState<_BlockedUserCard> createState() => _BlockedUserCardState();
}

class _BlockedUserCardState extends ConsumerState<_BlockedUserCard> {
  bool _busy = false;
  String? _error;
  Future<void> _unblock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(safetyRepositoryProvider).unblock(widget.user.id);
      if (!mounted) return;
      ref.invalidate(blockedUsersProvider);
      ref.invalidate(questionsProvider);
      ref.invalidate(questionProvider);
      ref.invalidate(helperOpenQuestionsProvider);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.user.name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text('해제하면 이 사용자의 콘텐츠와 상호작용이 다시 표시될 수 있습니다.'),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              onPressed: _busy ? null : _unblock,
              child: Text(_busy ? '해제 중…' : '차단 해제'),
            ),
          ),
        ],
      ),
    ),
  );
}
