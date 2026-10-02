import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/api_service.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/question.dart';
import '../questions/question_repository.dart';
import '../questions/travel_question_support.dart';
import 'guide_discovery_feed.dart';

class GuideDiscoverySection extends ConsumerStatefulWidget {
  const GuideDiscoverySection({super.key});

  @override
  ConsumerState<GuideDiscoverySection> createState() =>
      _GuideDiscoverySectionState();
}

class _GuideDiscoverySectionState extends ConsumerState<GuideDiscoverySection> {
  bool _opening = false;

  Future<void> _open(Question question, GuideDiscoveryFeed feed) async {
    if (_opening || !mounted) return;
    setState(() => _opening = true);
    try {
      // Never treat a compact row, or a previously visited detail, as
      // permission to claim. Detail performs a fresh server read.
      ref.invalidate(questionProvider(question.id));
      await context.push('/questions/${Uri.encodeComponent(question.id)}');
    } finally {
      if (mounted) {
        setState(() => _opening = false);
        await feed.refreshAfterDetail();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(guideDiscoveryFeedProvider);
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (feed.error != null && !feed.failedMore)
            _DiscoveryError(
              error: feed.error!,
              hasRows: feed.items.isNotEmpty,
              onRetry: feed.retry,
            ),
          if (feed.isLoading && !feed.isLoadingMore) const _DiscoveryLoading(),
          if (feed.hasLoaded &&
              feed.items.isEmpty &&
              feed.error == null &&
              !feed.isLoading)
            _DiscoveryEmpty(onRefresh: feed.refresh),
          for (final question in feed.items)
            _DiscoveryQuestionCard(
              question: question,
              onOpen: _opening ? null : () => _open(question, feed),
            ),
          if (feed.failedMore)
            _DiscoveryError(
              error: feed.error!,
              hasRows: feed.items.isNotEmpty,
              onRetry: feed.retry,
            ),
          if (feed.isLoadingMore) const _DiscoveryLoading(),
          if (feed.nextCursor != null && feed.error == null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              key: const ValueKey('discovery-load-more'),
              onPressed: feed.isLoading ? null : feed.loadMore,
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Text('더 보기'),
            ),
          ],
        ],
      ),
    );
  }
}

class _DiscoveryLoading extends StatelessWidget {
  const _DiscoveryLoading();

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Semantics(
        liveRegion: true,
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('지역의 질문을 불러오고 있어요'),
            SizedBox(height: 20),
            LinearProgressIndicator(minHeight: 2),
          ],
        ),
      ),
    ),
  );
}

class _DiscoveryQuestionCard extends StatelessWidget {
  const _DiscoveryQuestionCard({required this.question, required this.onOpen});
  final Question question;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final city = travelCityLabel(question.city, country: question.country);
    final region = question.regionName?.trim();
    return Card(
      key: ValueKey('discovery-question-${question.id}'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(question.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              region == null || region.isEmpty ? city : '$city · $region',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(question.category),
                Text('질문 보상 · 가상 ${formatPoints(question.rewardPoints)}'),
              ],
            ),
            if (question.createdAt != null) ...[
              const SizedBox(height: 8),
              Text(
                '질문 등록 ${formatDate(question.createdAt)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onOpen,
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Text('질문 자세히 보기', textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoveryError extends StatelessWidget {
  const _DiscoveryError({
    required this.error,
    required this.hasRows,
    required this.onRetry,
  });
  final Object error;
  final bool hasRows;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final code = error is ApiException ? (error as ApiException).code : '';
    final description = switch (code) {
      'HELPER_NOT_APPROVED' => '답변 참여 승인을 확인해주세요. 승인된 가이드만 질문을 확인할 수 있어요.',
      'ACCOUNT_SUSPENDED' => '현재 계정의 답변 참여가 제한되어 있어요.',
      'UNAUTHENTICATED' ||
      'unauthorized' ||
      'session_changed' => '로그인 상태를 확인한 뒤 다시 시도해주세요.',
      'INVALID_DISCOVERY_CURSOR' => '목록이 변경되었어요. 다시 시도하면 처음부터 확인해요.',
      _ when hasRows => '표시된 질문은 이전에 불러온 내용이에요. 연결을 확인한 뒤 다시 시도해주세요.',
      _ => '질문 목록을 확인하지 못했어요. 연결과 참여 상태를 확인한 뒤 다시 시도해주세요.',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '질문을 불러오지 못했어요',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(description),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('질문 다시 불러오기')),
          ],
        ),
      ),
    );
  }
}

class _DiscoveryEmpty extends StatelessWidget {
  const _DiscoveryEmpty({required this.onRefresh});
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Icon(
              Icons.chat_bubble_outline_rounded,
              size: 28,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('질문 다시 확인'),
          ),
        ],
      ),
    ),
  );
}
