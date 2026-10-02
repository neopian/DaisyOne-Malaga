import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/mvp_rules.dart';
import '../../core/services/api_service.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/answer.dart';
import '../../shared/models/evidence_link.dart';
import '../../shared/models/question.dart';
import '../../shared/models/question_comment.dart';
import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/status_chip.dart';
import '../../shared/widgets/guide_activity_card.dart';
import '../answers/answer_repository.dart';
import '../auth/auth_repository.dart';
import '../helper_application/helper_repository.dart';
import '../profile/profile_repository.dart';
import '../safety/safety_menu.dart';
import 'question_realtime.dart';
import 'question_repository.dart';

class QuestionDetailPage extends ConsumerStatefulWidget {
  const QuestionDetailPage({super.key, required this.questionId});

  final String questionId;

  @override
  ConsumerState<QuestionDetailPage> createState() => _QuestionDetailPageState();
}

class _QuestionDetailPageState extends ConsumerState<QuestionDetailPage> {
  // Keep only the user's unsent text above the refresh/error view. No question
  // data is cached here, and a failed poll never recreates an empty controller.
  final _comment = TextEditingController();
  late final AuthRepository _auth;
  String? _commentOwnerId;
  int _commentRevision = 0;
  bool _isCommentSubmitting = false;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authRepositoryProvider);
    _commentOwnerId = _auth.currentUser?.id;
    _auth.addListener(_handleAccountChange);
  }

  void _resetComment() {
    _commentRevision++;
    _comment.clear();
    _isCommentSubmitting = false;
  }

  void _handleAccountChange() {
    final owner = _auth.currentUser?.id;
    if (!mounted || owner == _commentOwnerId) return;
    setState(() {
      _commentOwnerId = owner;
      _resetComment();
    });
  }

  @override
  void didUpdateWidget(covariant QuestionDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.questionId != widget.questionId) _resetComment();
  }

  @override
  void dispose() {
    _auth.removeListener(_handleAccountChange);
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submitComment() async {
    if (_isCommentSubmitting || _commentOwnerId == null) return;
    final body = _comment.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    if (body.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('코멘트를 입력해 주세요.')));
      return;
    }
    final revision = _commentRevision;
    final questionId = widget.questionId;
    setState(() => _isCommentSubmitting = true);
    try {
      await ref
          .read(questionRepositoryProvider)
          .addComment(questionId: questionId, body: body);
      if (!mounted || revision != _commentRevision) return;
      // The editor may currently be hidden by a failed refresh. Clear the
      // acknowledged draft here so reconnection cannot offer it as a new post.
      _comment.clear();
      ref.invalidate(questionProvider(questionId));
      ref.invalidate(questionsProvider);
      ref.invalidate(helperOpenQuestionsProvider);
      messenger.showSnackBar(const SnackBar(content: Text('코멘트를 남겼습니다.')));
    } catch (error) {
      if (!mounted || revision != _commentRevision) return;
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted && revision == _commentRevision) {
        setState(() => _isCommentSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(questionRealtimeProvider);
    final questionId = widget.questionId;
    ref.listen(questionProvider(questionId), (_, next) {
      final error = next.error;
      if (error is ApiException &&
          const [401, 403, 404].contains(error.status) &&
          (_comment.text.isNotEmpty || _isCommentSubmitting)) {
        setState(_resetComment);
      }
    });
    final question = ref.watch(questionProvider(questionId));
    return AppPage(
      maxWidth: 760,
      title: '질문 상세',
      actions: [
        IconButton(
          tooltip: '새로고침',
          onPressed: () {
            ref.invalidate(questionProvider(questionId));
            ref.invalidate(helperApplicationProvider);
            ref.invalidate(guideSummaryProvider);
          },
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: Column(
        children: [
          if (question.hasError && _comment.text.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Text(
                '입력한 코멘트는 이 화면에 남아 있어요. 연결 후 다시 시도해주세요.',
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: AsyncValueView(
              value: question,
              onRetry: () => ref.invalidate(questionProvider(questionId)),
              data: (data) => _QuestionDetail(
                question: data,
                commentController: _comment,
                isCommentSubmitting: _isCommentSubmitting,
                onSubmitComment: _submitComment,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuestionDetail extends ConsumerWidget {
  const _QuestionDetail({
    required this.question,
    required this.commentController,
    required this.isCommentSubmitting,
    required this.onSubmitComment,
  });

  final Question question;
  final TextEditingController commentController;
  final bool isCommentSubmitting;
  final VoidCallback onSubmitComment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider).asData?.value;
    final helperApplication = ref
        .watch(helperApplicationProvider)
        .asData
        ?.value;
    final isOwner = profile?.id == question.userId;
    final isAssignedHelper = profile?.id == question.assignedHelperUserId;
    final canAcceptQuestion = MvpRules.canAcceptQuestion(
      questionStatus: question.status,
      helperApproved: helperApplication?.isApproved ?? false,
      questionOwnerId: question.userId,
      currentUserId: profile?.id,
    );
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
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusChip(
                      label: question.status,
                      emphasis: question.isOpen,
                    ),
                    StatusChip(label: question.urgency),
                    Text(
                      formatPoints(question.rewardPoints),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SafetyMenu(
                      targetType: 'question',
                      targetId: question.id,
                      authorId: question.userId,
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
        if ((isOwner || isAssignedHelper) &&
            question.assignedHelper != null) ...[
          const SizedBox(height: 12),
          AssignedGuideCard(guide: question.assignedHelper!),
          Align(
            alignment: Alignment.centerRight,
            child: SafetyMenu(
              targetType: 'user',
              targetId: question.assignedHelper!.id,
              authorId: question.assignedHelper!.id,
              authorName: question.assignedHelper!.name,
            ),
          ),
        ],
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
                  errorBuilder: (_, _, _) => const SizedBox(
                    width: 160,
                    child: Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              ),
            ),
          ),
        ],
        if ((isOwner || isAssignedHelper) &&
            profile?.isSuspended != true &&
            (question.isAssigned || question.isAnswered))
          TextButton(
            onPressed: () => context.push(
              Uri(
                path: '/account/exchange-issues',
                queryParameters: {'question': question.id},
              ).toString(),
            ),
            child: const Text('이 진행의 문제 기록'),
          ),
        const SizedBox(height: 12),
        _QuestionCommentsSection(
          question: question,
          currentUserId: profile?.id,
          commentController: commentController,
          isCommentSubmitting: isCommentSubmitting,
          onSubmitComment: onSubmitComment,
        ),
        const SizedBox(height: 12),
        if (canAcceptQuestion) ...[
          const _InfoCard(
            icon: Icons.place_outlined,
            title: '등록한 활동 지역의 질문만 수락할 수 있어요. 수락 시 참여 상태와 지역을 다시 확인합니다.',
          ),
          const SizedBox(height: 12),
          _ActionCard(
            icon: Icons.handshake_outlined,
            title: '질문 수락',
            buttonLabel: '1:1로 수락',
            onPressed: () => _acceptQuestion(context, ref, question.id),
          ),
        ],
        if (question.isOpen && isOwner) ...[
          const _InfoCard(
            icon: Icons.info_outline,
            title: '내가 작성한 질문은 답변자로 수락할 수 없습니다',
          ),
          const SizedBox(height: 12),
          _CancelQuestionCard(question: question),
        ],
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
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await ref.read(questionRepositoryProvider).acceptQuestion(questionId);
      container.invalidate(questionProvider(questionId));
      container.invalidate(questionsProvider);
      container.invalidate(helperOpenQuestionsProvider);
      container.invalidate(guideSummaryProvider);
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
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await ref
          .read(answerRepositoryProvider)
          .acceptAnswer(questionId: question.id, answerId: answer.id);
      container.invalidate(questionProvider(question.id));
      container.invalidate(questionsProvider);
      container.invalidate(currentProfileProvider);
      container.invalidate(pointTransactionsProvider);
      container.invalidate(guideSummaryProvider);
      messenger.showSnackBar(const SnackBar(content: Text('답변을 채택했습니다.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

class _CancelQuestionCard extends ConsumerStatefulWidget {
  const _CancelQuestionCard({required this.question});

  final Question question;

  @override
  ConsumerState<_CancelQuestionCard> createState() =>
      _CancelQuestionCardState();
}

class _CancelQuestionCardState extends ConsumerState<_CancelQuestionCard> {
  bool _isCancelling = false;

  Future<void> _cancel() async {
    if (_isCancelling) return;
    setState(() => _isCancelling = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('질문을 취소할까요?'),
          content: Text(
            '아직 답변자가 수락하지 않은 질문만 취소할 수 있습니다. '
            '취소하면 보류 중인 ${formatPoints(widget.question.rewardPoints)}가 '
            'mock 포인트 잔액으로 환급됩니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('돌아가기'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('취소하고 환급받기'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      final container = ProviderScope.containerOf(context, listen: false);
      final repository = ref.read(questionRepositoryProvider);
      final questionId = widget.question.id;
      await repository.cancelQuestion(questionId);
      // Keep shared balances and feeds fresh even if this page was dismissed.
      container.invalidate(questionProvider(questionId));
      container.invalidate(questionsProvider);
      container.invalidate(helperOpenQuestionsProvider);
      container.invalidate(currentProfileProvider);
      container.invalidate(pointTransactionsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('질문을 취소하고 보류 포인트를 환급했습니다.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('질문 취소', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('답변자가 수락하기 전에는 질문을 취소하고 보류된 mock 포인트를 돌려받을 수 있습니다.'),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: _isCancelling ? null : _cancel,
                icon: _isCancelling
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cancel_outlined),
                label: const Text('질문 취소 및 환급'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestionCommentsSection extends StatelessWidget {
  const _QuestionCommentsSection({
    required this.question,
    required this.currentUserId,
    required this.commentController,
    required this.isCommentSubmitting,
    required this.onSubmitComment,
  });

  final Question question;
  final String? currentUserId;
  final TextEditingController commentController;
  final bool isCommentSubmitting;
  final VoidCallback onSubmitComment;

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
            _CommentComposer(
              controller: commentController,
              isSubmitting: isCommentSubmitting,
              onSubmit: onSubmitComment,
            ),
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

class _CommentComposer extends StatelessWidget {
  const _CommentComposer({
    required this.controller,
    required this.isSubmitting,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool isSubmitting;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          enabled: !isSubmitting,
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
            onPressed: isSubmitting ? null : onSubmit,
            icon: isSubmitting
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
        if (!isMine)
          SafetyMenu(
            targetType: 'comment',
            targetId: comment.id,
            authorId: comment.userId,
            authorName: authorName,
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
  final Future<void> Function() onAccept;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Icon(Icons.forum_outlined),
                Text('답변', style: Theme.of(context).textTheme.titleLarge),
                StatusChip(
                  label: answer.status,
                  emphasis: answer.status == 'accepted',
                ),
                SafetyMenu(
                  targetType: 'answer',
                  targetId: answer.id,
                  authorId: answer.helperUserId,
                  authorName: '답변자',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              answer.createdAt == null
                  ? '답변 작성 시각 정보 없음'
                  : '답변 작성 · ${DateFormat('yyyy년 M월 d일 HH:mm:ss').format(answer.createdAt!.toLocal())} (기기 시간 기준)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
              _BusyFilledButton(
                onPressed: onAccept,
                icon: Icons.check_circle_outline,
                label: '답변 채택',
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
        final messenger = ScaffoldMessenger.of(context);
        if (!MvpRules.isValidEvidenceUrl(link.url)) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('안전한 http 또는 https 근거 URL만 열 수 있습니다.'),
            ),
          );
          return;
        }
        try {
          final opened = await launchUrl(
            Uri.parse(link.url),
            mode: LaunchMode.externalApplication,
          );
          if (!opened && context.mounted) {
            messenger.showSnackBar(
              const SnackBar(content: Text('근거 링크를 열 수 없습니다.')),
            );
          }
        } catch (_) {
          if (!context.mounted) return;
          messenger.showSnackBar(
            const SnackBar(content: Text('근거 링크를 열 수 없습니다.')),
          );
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
  final FutureOr<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: _BusyFilledButton(
                onPressed: onPressed,
                label: buttonLabel,
              ),
            ),
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

class _BusyFilledButton extends StatefulWidget {
  const _BusyFilledButton({
    required this.onPressed,
    required this.label,
    this.icon,
  });
  final FutureOr<void> Function() onPressed;
  final String label;
  final IconData? icon;
  @override
  State<_BusyFilledButton> createState() => _BusyFilledButtonState();
}

class _BusyFilledButtonState extends State<_BusyFilledButton> {
  bool _busy = false;
  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onPressed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: _busy ? null : _run,
    icon: _busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : widget.icon == null
        ? const SizedBox.shrink()
        : Icon(widget.icon),
    label: Text(widget.label),
  );
}
