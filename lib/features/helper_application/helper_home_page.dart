import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/empty_state.dart';
import '../questions/question_home_page.dart';
import '../questions/question_repository.dart';
import 'helper_repository.dart';

class HelperHomePage extends ConsumerWidget {
  const HelperHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final application = ref.watch(helperApplicationProvider);
    return AppPage(
      title: '답변자 홈',
      actions: [
        IconButton(
          tooltip: '새로고침',
          onPressed: () {
            ref.invalidate(helperApplicationProvider);
            ref.invalidate(helperOpenQuestionsProvider);
          },
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: AsyncValueView(
        value: application,
        data: (app) {
          if (app == null) {
            return _Gate(
              icon: Icons.person_add_alt_outlined,
              title: '답변자 신청이 필요합니다',
              buttonLabel: '신청하기',
              onPressed: () => context.go('/helper/apply'),
            );
          }
          if (!app.isApproved) {
            return _Gate(
              icon: Icons.hourglass_top,
              title: app.isPending ? '승인 대기 중입니다' : '현재 답변할 수 없습니다',
              buttonLabel: '상태 확인',
              onPressed: () => context.go('/helper/waiting'),
            );
          }
          final questions = ref.watch(helperOpenQuestionsProvider);
          return AsyncValueView(
            value: questions,
            data: (items) {
              if (items.isEmpty) {
                return const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: '수락 가능한 질문이 없습니다',
                );
              }
              return RefreshIndicator(
                onRefresh: () async =>
                    ref.invalidate(helperOpenQuestionsProvider),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    for (final question in items)
                      QuestionCard(question: question),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Gate extends StatelessWidget {
  const _Gate({
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
          ],
        ),
      ),
    );
  }
}
