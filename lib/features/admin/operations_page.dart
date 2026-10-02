import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/geo/city_catalog.g.dart';
import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/travel_city_picker.dart';
import '../questions/travel_question_support.dart';
import 'operations_feed.dart';
import 'operations_repository.dart';

class OperationsPage extends ConsumerWidget {
  const OperationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(operationsFeedProvider);
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) => AppPage(
        title: '응답 대기 현황',
        maxWidth: 760,
        actions: [
          IconButton(
            tooltip: '현황 새로고침',
            onPressed: feed.isLoading || !feed.canRead ? null : feed.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        body: RefreshIndicator(
          onRefresh: feed.refresh,
          child: ListView(
            key: ValueKey('operations-${feed.city?.id}-${feed.status.name}'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              const Text('진행 상황 확인용이며 자동 배정·환불은 하지 않습니다'),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const ValueKey('operations-city-picker'),
                onPressed: !feed.canRead
                    ? null
                    : () async {
                        final city = await showTravelCityPicker(context);
                        if (context.mounted && city != null) {
                          await feed.selectCity(city);
                        }
                      },
                icon: const Icon(Icons.location_city_outlined),
                label: Text(
                  feed.city == null
                      ? '전체 지역 · 도시 선택'
                      : '${feed.city!.countryKo} · ${feed.city!.cityKo}',
                  textAlign: TextAlign.center,
                ),
              ),
              if (feed.city != null)
                TextButton(
                  key: const ValueKey('operations-all-cities'),
                  onPressed: feed.canRead ? () => feed.selectCity(null) : null,
                  child: const Text('전체 지역 보기'),
                ),
              const SizedBox(height: 16),
              const Text('선택 지역의 상태별 전체 건수'),
              const SizedBox(height: 4),
              Text(
                '숨김·제한된 질문을 포함합니다. 상태를 눌러 목록을 확인하세요.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (final status in OperationsStatus.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Semantics(
                    selected: feed.status == status,
                    child: OutlinedButton(
                      key: ValueKey('operations-status-${status.name}'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.all(12),
                        backgroundColor: feed.status == status
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : null,
                      ),
                      onPressed: feed.canRead
                          ? () => feed.selectStatus(status)
                          : null,
                      child: Column(
                        children: [
                          Text(status.label, textAlign: TextAlign.center),
                          Text(
                            feed.summary == null
                                ? feed.error == null && feed.canRead
                                      ? '건수 확인 중'
                                      : '건수 확인 불가'
                                : '${feed.summary!.count(status)}건',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              const Text('질문 등록이 오래된 순'),
              const SizedBox(height: 4),
              Text(
                '등록·최근 변경은 기록된 시각을 기기 시간으로 표시합니다. 최근 변경은 배정 시각과 다를 수 있습니다.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              if (feed.accessDenied)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('관리자 권한을 확인할 수 없습니다. 로그인과 계정 권한을 확인해주세요.'),
                ),
              if (feed.error != null) _OperationsError(feed: feed),
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
                        Text('응답 대기 현황을 확인하고 있어요'),
                      ],
                    ),
                  ),
                ),
              if (feed.hasLoaded &&
                  feed.items.isEmpty &&
                  feed.error == null &&
                  !feed.isLoading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    '선택한 지역에 ${feed.status.label} 질문이 없습니다.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final question in feed.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _OperationsQuestionCard(
                    question: question,
                    onOpen: () async {
                      await context.push(
                        '/questions/${Uri.encodeComponent(question.id)}',
                      );
                      if (context.mounted) await feed.refresh();
                    },
                  ),
                ),
              if (feed.nextCursor != null && feed.error == null)
                OutlinedButton(
                  key: const ValueKey('operations-load-more'),
                  onPressed: feed.isLoading ? null : feed.loadMore,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text('더 보기'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OperationsError extends StatelessWidget {
  const _OperationsError({required this.feed});
  final OperationsFeed feed;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('응답 대기 현황을 불러오지 못했어요'),
          const SizedBox(height: 8),
          Text(
            feed.items.isNotEmpty
                ? '표시된 질문은 이전에 불러온 내용입니다. 현재 건수는 확인할 수 없습니다.'
                : '연결과 로그인 상태를 확인한 뒤 다시 시도해주세요.',
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: feed.canRead && !feed.isLoading ? feed.retry : null,
            child: const Text('다시 시도'),
          ),
        ],
      ),
    ),
  );
}

class _OperationsQuestionCard extends StatelessWidget {
  const _OperationsQuestionCard({required this.question, required this.onOpen});
  final OperationsQuestion question;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final dates = DateFormat('yyyy.MM.dd HH:mm');
    return Card(
      key: ValueKey('operations-question-${question.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(question.status.label),
            const SizedBox(height: 8),
            Text(
              question.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '${CityCatalog.countryLabel(question.country)} · '
              '${travelCityLabel(question.city, country: question.country)}',
            ),
            const SizedBox(height: 12),
            Text('등록 · ${dates.format(question.createdAt.toLocal())}'),
            Text('최근 변경 · ${dates.format(question.updatedAt.toLocal())}'),
            if (question.flags.isNotEmpty) ...[
              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '진행 확인이 필요한 상태',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                      for (final flag in question.flags)
                        Text(
                          '• $flag',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onOpen,
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Text('질문 상세 확인', textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
