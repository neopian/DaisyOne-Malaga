import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/formatters.dart';
import '../../shared/models/answer.dart';
import '../../shared/models/evidence_link.dart';
import '../../shared/models/question.dart';
import '../../shared/models/question_comment.dart';
import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/status_chip.dart';
import '../answers/answer_repository.dart';
import '../helper_application/helper_repository.dart';
import '../profile/profile_repository.dart';
import 'question_repository.dart';

class QuestionDetailPage extends ConsumerWidget {
  const QuestionDetailPage({super.key, required this.questionId});

  final String questionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final question = ref.watch(questionProvider(questionId));
    return AppPage(
      title: '질문 상세',
      actions: [
        IconButton(
          tooltip: '새로고침',
          onPressed: () => ref.invalidate(questionProvider(questionId)),
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: AsyncValueView(
        value: question,
        data: (data) => _QuestionDetail(question: data),
      ),
    );
  }
}

class _QuestionDetail extends ConsumerWidget {
  const _QuestionDetail({required this.question});

  final Question question;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider).asData?.value;
    final helperApplication = ref
        .watch(helperApplicationProvider)
        .asData
        ?.value;
    final isOwner = profile?.id == question.userId;
    final isAssignedHelper = profile?.id == question.assignedHelperUserId;
    final answer = question.submittedAnswer;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    StatusChip(
                      label: question.status,
                      emphasis: question.isOpen,
                    ),
                    const SizedBox(width: 8),
                    StatusChip(label: question.urgency),
                    const Spacer(),
                    Text(
                      formatPoints(question.rewardPoints),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  question.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(question.body),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    StatusChip(label: question.category),
                    StatusChip(label: question.locationLabel),
                    StatusChip(label: formatDate(question.createdAt)),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (question.images.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: question.images.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) => ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  question.images[index],
                  width: 160,
                  height: 132,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        _QuestionCommentsSection(
          question: question,
          currentUserId: profile?.id,
        ),
        const SizedBox(height: 12),
        if (question.isOpen && (helperApplication?.isApproved ?? false))
          _ActionCard(
            icon: Icons.handshake_outlined,
            title: '질문 수락',
            buttonLabel: '1:1로 수락',
            onPressed: () => _acceptQuestion(context, ref, question.id),
          ),
        if (question.isOpen &&
            !(helperApplication?.isApproved ?? false) &&
            !isOwner)
          const _InfoCard(
            icon: Icons.verified_user_outlined,
            title: '승인된 답변자만 수락할 수 있습니다',
          ),
        if (isAssignedHelper && question.isAssigned)
          _ActionCard(
            icon: Icons.edit_note_outlined,
            title: '답변 작성',
            buttonLabel: '근거와 함께 답변',
            onPressed: () => context.go('/answers/new/${question.id}'),
          ),
        if (answer != null) ...[
          const SizedBox(height: 12),
          _AnswerCard(
            answer: answer,
            canAccept: isOwner && question.isAnswered,
            onAccept: () => _acceptAnswer(context, ref, question, answer),
          ),
        ],
        if (isOwner && question.isAssigned && answer == null)
          const _InfoCard(icon: Icons.hourglass_top, title: '답변자가 확인 중입니다'),
      ],
    );
  }

  Future<void> _acceptQuestion(
    BuildContext context,
    WidgetRef ref,
    String questionId,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(questionRepositoryProvider).acceptQuestion(questionId);
      ref.invalidate(questionProvider(questionId));
      ref.invalidate(questionsProvider);
      ref.invalidate(helperOpenQuestionsProvider);
      messenger.showSnackBar(const SnackBar(content: Text('질문을 수락했습니다.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _acceptAnswer(
    BuildContext context,
    WidgetRef ref,
    Question question,
    Answer answer,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(answerRepositoryProvider)
          .acceptAnswer(questionId: question.id, answerId: answer.id);
      ref.invalidate(questionProvider(question.id));
      ref.invalidate(questionsProvider);
      ref.invalidate(currentProfileProvider);
      messenger.showSnackBar(const SnackBar(content: Text('답변을 채택했습니다.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

class _QuestionCommentsSection extends StatelessWidget {
  const _QuestionCommentsSection({
    required this.question,
    required this.currentUserId,
  });

  final Question question;
  final String? currentUserId;

  @override
  Widget build(BuildContext context) {
    final comments = question.comments;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.mode_comment_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '코멘트',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Text(
                  '${comments.length}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _CommentComposer(questionId: question.id),
            if (comments.isEmpty) ...[
              const SizedBox(height: 14),
              Text(
                '아직 코멘트가 없습니다.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ] else ...[
              const Divider(height: 28),
              for (final comment in comments) ...[
                _QuestionCommentTile(
                  comment: comment,
                  isMine: comment.userId == currentUserId,
                ),
                if (comment != comments.last) const Divider(height: 24),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _CommentComposer extends ConsumerStatefulWidget {
  const _CommentComposer({required this.questionId});

  final String questionId;

  @override
  ConsumerState<_CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends ConsumerState<_CommentComposer> {
  final _controller = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          enabled: !_isSubmitting,
          minLines: 2,
          maxLines: 4,
          maxLength: 600,
          textInputAction: TextInputAction.newline,
          decoration: const InputDecoration(
            hintText: '추가로 공유할 내용을 남겨주세요',
            prefixIcon: Icon(Icons.chat_bubble_outline),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _isSubmitting ? null : _submit,
            icon: _isSubmitting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_comment_outlined),
            label: const Text('남기기'),
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final body = _controller.text.trim();
    final messenger = ScaffoldMessenger.of(context);

    if (body.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('코멘트를 입력해 주세요.')));
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await ref
          .read(questionRepositoryProvider)
          .addComment(questionId: widget.questionId, body: body);
      _controller.clear();
      ref.invalidate(questionProvider(widget.questionId));
      messenger.showSnackBar(const SnackBar(content: Text('코멘트를 남겼습니다.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }
}

class _QuestionCommentTile extends StatelessWidget {
  const _QuestionCommentTile({required this.comment, required this.isMine});

  final QuestionComment comment;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final authorName = isMine
        ? '나'
        : (comment.authorName?.isNotEmpty == true
              ? comment.authorName!
              : '사용자');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 18,
          backgroundImage: comment.authorAvatarUrl?.isNotEmpty == true
              ? NetworkImage(comment.authorAvatarUrl!)
              : null,
          child: comment.authorAvatarUrl?.isNotEmpty == true
              ? null
              : const Icon(Icons.person_outline, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    authorName,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (comment.createdAt != null)
                    Text(
                      formatDate(comment.createdAt),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(comment.body),
            ],
          ),
        ),
      ],
    );
  }
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({
    required this.answer,
    required this.canAccept,
    required this.onAccept,
  });

  final Answer answer;
  final bool canAccept;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '답변',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                StatusChip(
                  label: answer.status,
                  emphasis: answer.status == 'accepted',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(answer.body),
            const Divider(height: 28),
            Text('근거 요약', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(answer.evidenceSummary),
            const SizedBox(height: 12),
            Text('확인 방식', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(answer.verificationMethod),
            const SizedBox(height: 12),
            for (final link in answer.evidenceLinks) _EvidenceTile(link: link),
            if (canAccept) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onAccept,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('답변 채택'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EvidenceTile extends StatelessWidget {
  const _EvidenceTile({required this.link});

  final EvidenceLink link;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.link),
      title: Text(link.title?.isNotEmpty == true ? link.title! : link.url),
      subtitle: Text(link.description ?? link.sourceType),
      trailing: const Icon(Icons.open_in_new),
      onTap: () async {
        final uri = Uri.tryParse(link.url);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.buttonLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon),
            const SizedBox(width: 12),
            Expanded(child: Text(title)),
          ],
        ),
      ),
    );
  }
}
