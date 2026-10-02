import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/formatters.dart';
import '../../shared/models/question.dart';
import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/status_chip.dart';
import '../questions/question_realtime.dart';
import '../questions/travel_question_support.dart';
import 'activity_feed.dart';
import 'activity_repository.dart';

class ActivityPage extends ConsumerWidget {
  const ActivityPage({super.key, required this.role});

  final ActivityRole role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(questionRealtimeProvider);
    final feed = ref.watch(activityFeedProvider(role));
    final traveler = role == ActivityRole.traveler;
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) => AppPage(
        title: traveler ? '내 질문' : '맡은 질문',
        maxWidth: 760,
        actions: [
          IconButton(
            tooltip: '목록 새로고침',
            onPressed: feed.isLoading ? null : feed.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        body: RefreshIndicator(
          onRefresh: feed.refresh,
          child: ListView(
            key: PageStorageKey('activity-${role.name}-${feed.view.name}'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Text(
                traveler
                    ? '질문의 진행 상황과 도착한 답변을 여기에서 확인해요.'
                    : '수락한 질문으로 돌아가 답변을 이어갈 수 있어요.',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final view in ActivityView.values)
                    ChoiceChip(
                      key: ValueKey('activity-view-${view.name}'),
                      label: Text(
                        view == ActivityView.active ? '진행 중' : '지난 질문',
                      ),
                      selected: feed.view == view,
                      onSelected: (_) => feed.selectView(view),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (feed.error != null)
                _ActivityError(
                  hasRows: feed.items.isNotEmpty,
                  onRetry: feed.retry,
                ),
              if (feed.isLoading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Semantics(
                    liveRegion: true,
                    child: const Column(
                      children: [
                        SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(height: 12),
                        Text('질문 목록을 확인하고 있어요'),
                      ],
                    ),
                  ),
                ),
              if (feed.hasLoaded &&
                  feed.items.isEmpty &&
                  feed.error == null &&
                  !feed.isLoading)
                _ActivityEmpty(role: role, view: feed.view),
              for (final question in feed.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _ActivityQuestionCard(
                    question: question,
                    role: role,
                    onOpen: () async {
                      await context.push('/questions/${question.id}');
                      if (context.mounted) await feed.refresh();
                    },
                  ),
                ),
              if (feed.nextCursor != null && feed.error == null)
                OutlinedButton(
                  key: const ValueKey('activity-load-more'),
                  onPressed: feed.isLoading ? null : feed.loadMore,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text('더 보기'),
                ),
              const SizedBox(height: 12),
              Text(
                '포인트는 앱 안에서만 사용하는 가상 포인트이며 현금 가치·구매·출금 기능은 없습니다.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityError extends StatelessWidget {
  const _ActivityError({required this.hasRows, required this.onRetry});

  final bool hasRows;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('질문 목록을 확인하지 못했어요'),
          const SizedBox(height: 8),
          Text(
            hasRows
                ? '표시된 질문은 이전에 불러온 내용이에요. 연결을 확인한 뒤 다시 시도해주세요.'
                : '연결과 로그인 상태를 확인한 뒤 다시 시도해주세요.',
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
        ],
      ),
    ),
  );
}

class _ActivityEmpty extends StatelessWidget {
  const _ActivityEmpty({required this.role, required this.view});

  final ActivityRole role;
  final ActivityView view;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      children: [
        Text(
          view == ActivityView.history
              ? '지난 질문이 없어요'
              : role == ActivityRole.traveler
              ? '진행 중인 내 질문이 없어요'
              : '진행 중인 맡은 질문이 없어요',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => context.go(
            role == ActivityRole.traveler ? '/questions/new' : '/helper/home',
          ),
          child: Text(role == ActivityRole.traveler ? '질문하기' : '답변할 질문 찾기'),
        ),
      ],
    ),
  );
}

class _ActivityQuestionCard extends StatelessWidget {
  const _ActivityQuestionCard({
    required this.question,
    required this.role,
    required this.onOpen,
  });

  final Question question;
  final ActivityRole role;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final traveler = role == ActivityRole.traveler;
    final (description, action) = switch (question.status) {
      'open' => ('답변자를 기다리고 있어요. 답변 시간은 보장되지 않습니다.', '질문 확인'),
      'assigned' when traveler => ('가이드가 질문을 수락했어요. 답변을 기다리고 있어요.', '진행 상황 확인'),
      'assigned' => ('맡은 질문을 확인하고 근거와 함께 답변해주세요.', '답변 이어가기'),
      'answered' when traveler => ('답변과 근거를 확인하고 채택 여부를 결정해주세요.', '답변 검토'),
      'answered' => ('답변을 보냈어요. 여행자의 채택을 기다리고 있어요.', '보낸 답변 확인'),
      'accepted' when traveler => ('답변을 채택한 질문이에요.', '채택한 답변 보기'),
      'accepted' => ('답변이 채택되었어요. 가상 포인트 내역을 확인할 수 있어요.', '완료한 답변 보기'),
      'cancelled' => ('취소된 질문이에요.', '지난 질문 보기'),
      'expired' => ('기한이 종료된 질문이에요.', '지난 질문 보기'),
      _ => ('질문의 현재 상태를 상세 화면에서 확인해주세요.', '질문 확인'),
    };
    return Card(
      key: ValueKey('activity-question-${question.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [StatusChip(label: question.status, compact: true)],
            ),
            const SizedBox(height: 12),
            Text(
              question.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(travelCityLabel(question.city, country: question.country)),
            if (question.createdAt != null) ...[
              const SizedBox(height: 8),
              Text('질문 등록 ${formatDate(question.createdAt)}'),
            ],
            const SizedBox(height: 8),
            Text(description),
            const SizedBox(height: 8),
            Text('질문 보상 · 가상 ${formatPoints(question.rewardPoints)}'),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onOpen,
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              child: Text(action, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
