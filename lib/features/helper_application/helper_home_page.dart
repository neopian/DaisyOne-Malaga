import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/guide_activity_card.dart';
import '../questions/question_home_page.dart';
import '../questions/question_realtime.dart';
import '../questions/question_repository.dart';
import 'helper_repository.dart';

class HelperHomePage extends ConsumerWidget {
  const HelperHomePage({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(guideSummaryProvider);
    ref.invalidate(helperApplicationProvider);
    ref.invalidate(helperOpenQuestionsProvider);
    // Let each independent section retain its own retry/error state.
    await Future.wait([
      ref
          .read(guideSummaryProvider.future)
          .then<void>((_) {}, onError: (_, _) {}),
      ref
          .read(helperApplicationProvider.future)
          .then<void>((_) {}, onError: (_, _) {}),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(questionRealtimeProvider);
    final summary = ref.watch(guideSummaryProvider);
    final application = ref.watch(helperApplicationProvider);
    final theme = Theme.of(context);
    return AppPage(
      title: '로컬 가이드 홈',
      actions: [
        IconButton(
          tooltip: '새로고침',
          onPressed: () => _refresh(ref),
          icon: const Icon(Icons.refresh_rounded),
        ),
        IconButton(
          tooltip: '질문자로 전환',
          onPressed: () => context.go('/home'),
          icon: const Icon(Icons.home_outlined),
        ),
        const SizedBox(width: 8),
      ],
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: RefreshIndicator(
            onRefresh: () => _refresh(ref),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
              children: [
                Text('내 활동 지역의 질문', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  '현지에서 아는 것이 여행자에게 도움이 돼요.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                // The useful feed comes first and is independent from statistics:
                // a failed guide/me request must not hide available questions.
                application.when(
                  loading: () =>
                      const _LoadingSection(label: '답변 참여 상태를 확인하고 있어요'),
                  error: (_, _) => _RetryCard(
                    title: '답변 참여 상태를 불러오지 못했어요',
                    onRetry: () => ref.invalidate(helperApplicationProvider),
                  ),
                  data: (app) {
                    if (app == null) {
                      return _Gate(
                        icon: Icons.person_add_alt_outlined,
                        title: '내 지역의 여행자를 도와주세요',
                        description:
                            '활동 지역과 현지 경험을 등록하고 답변 참여 승인을 받아 시작할 수 있어요.',
                        buttonLabel: '답변자 신청하기',
                        onPressed: () => context.go('/helper/apply'),
                      );
                    }
                    if (!app.isApproved) {
                      return _Gate(
                        icon: Icons.hourglass_top_rounded,
                        title: app.isPending
                            ? '신청을 검토하고 있어요'
                            : '현재 답변에 참여할 수 없어요',
                        description: '신청 결과와 참여 상태를 확인해 주세요.',
                        buttonLabel: '신청 상태 확인',
                        onPressed: () => context.go('/helper/waiting'),
                      );
                    }
                    return const _OpenQuestions();
                  },
                ),
                const SizedBox(height: 24),
                GuideActivitySection(
                  value: summary,
                  onRetry: () => ref.invalidate(guideSummaryProvider),
                ),
                const SizedBox(height: 28),
                const _HowToHelp(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OpenQuestions extends ConsumerWidget {
  const _OpenQuestions();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(helperOpenQuestionsProvider)
      .when(
        loading: () => const _LoadingSection(label: '지역의 질문을 불러오고 있어요'),
        error: (_, _) => _RetryCard(
          title: '질문을 불러오지 못했어요',
          onRetry: () => ref.invalidate(helperOpenQuestionsProvider),
        ),
        data: (items) => items.isEmpty
            ? Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 28,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '지금 수락 가능한 질문이 없어요',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '새 질문이 올라오면 여기에서 확인할 수 있어요.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: () =>
                            ref.invalidate(helperOpenQuestionsProvider),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('질문 다시 확인'),
                      ),
                    ],
                  ),
                ),
              )
            : Column(
                children: [
                  for (final question in items)
                    QuestionCard(question: question),
                ],
              ),
      );
}

class _LoadingSection extends StatelessWidget {
  const _LoadingSection({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    ),
  );
}

class _HowToHelp extends StatelessWidget {
  const _HowToHelp();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('현지 경험을 도움으로', style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          const _HelpStep(number: '1', text: '잘 아는 지역의 질문을 골라 1:1로 수락해요.'),
          const SizedBox(height: 12),
          const _HelpStep(number: '2', text: '직접 아는 내용과 확인 가능한 근거 링크로 답변해요.'),
          const SizedBox(height: 12),
          const _HelpStep(number: '3', text: '여행자가 채택하면 도움 기록과 가상 포인트가 쌓여요.'),
        ],
      ),
    );
  }
}

class _HelpStep extends StatelessWidget {
  const _HelpStep({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 26,
          child: Text(
            number,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _Gate extends StatelessWidget {
  const _Gate({
    required this.icon,
    required this.title,
    required this.description,
    required this.buttonLabel,
    required this.onPressed,
  });
  final IconData icon;
  final String title;
  final String description;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Icon(icon, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: 18),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            description,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
        ],
      ),
    ),
  );
}

class _RetryCard extends StatelessWidget {
  const _RetryCard({required this.title, required this.onRetry});
  final String title;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '연결을 확인한 뒤 다시 시도해 주세요.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('다시 시도'),
          ),
        ],
      ),
    ),
  );
}
