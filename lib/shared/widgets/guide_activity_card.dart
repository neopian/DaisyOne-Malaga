import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/formatters.dart';
import '../models/guide_summary.dart';

class GuideActivitySection extends StatelessWidget {
  const GuideActivitySection({
    super.key,
    required this.value,
    required this.onRetry,
  });

  final AsyncValue<GuideSummary> value;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => value.when(
    data: (summary) => GuideActivityCard(summary: summary),
    loading: () => const Card(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('로컬 가이드 활동을 불러오는 중'),
            SizedBox(height: 16),
            LinearProgressIndicator(minHeight: 2),
          ],
        ),
      ),
    ),
    error: (_, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '활동 기록을 불러오지 못했어요',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '연결을 확인하고 다시 시도해 주세요. 수치는 서버 기록을 확인한 뒤 표시해요.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('활동 기록 다시 불러오기'),
            ),
          ],
        ),
      ),
    ),
  );
}

class GuideActivityCard extends StatelessWidget {
  const GuideActivityCard({super.key, required this.summary});

  final GuideSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('로컬 가이드 활동', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              guideApplicationLabel(summary.applicationStatus),
              style: secondaryStyle,
            ),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final columns = constraints.maxWidth >= 300 * scale ? 3 : 1;
                final width =
                    (constraints.maxWidth - (columns - 1) * 16) / columns;
                return Wrap(
                  spacing: 16,
                  runSpacing: 18,
                  children: [
                    SizedBox(
                      width: width,
                      child: _ActivityMetric(
                        label: '채택된 답변',
                        value: '${summary.acceptedAnswerCount}건',
                        valueKey: const Key('guide-accepted-count'),
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _ActivityMetric(
                        label: '받은 포인트',
                        value: formatPoints(summary.earnedMockPoints),
                        valueKey: const Key('guide-earned-points'),
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _ActivityMetric(
                        label: '채택 대기',
                        value: formatPoints(summary.pendingMockPoints),
                        valueKey: const Key('guide-pending-points'),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 18),
            Text(
              '여행자가 답변을 채택하면 포인트가 지급돼요. 질문 수락·답변 제출만으로는 지급되지 않아요.',
              style: secondaryStyle,
            ),
            const SizedBox(height: 4),
            Text('가상 포인트와 실제 채택 기록이 쌓입니다. 현금 가치·구매·출금 기능은 없습니다.', style: secondaryStyle),
            const Divider(height: 32),
            Text('등록한 활동 지역', style: theme.textTheme.labelLarge),
            const SizedBox(height: 10),
            GuideRegionList(regions: summary.activityRegions),
            const SizedBox(height: 6),
            Text(
              '신청 시 등록한 지역과 실제 채택 기록이에요. 전문성 인증을 의미하지 않아요.',
              style: secondaryStyle,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityMetric extends StatelessWidget {
  const _ActivityMetric({
    required this.label,
    required this.value,
    required this.valueKey,
  });

  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          key: valueKey,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.8,
          ),
        ),
      ],
    );
  }
}

class GuideRegionList extends StatelessWidget {
  const GuideRegionList({super.key, required this.regions});
  final List<GuideActivityRegion> regions;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: regions.isEmpty
        ? [const Text('아직 등록한 활동 지역이 없어요.')]
        : [
            for (final label
                in regions.map((region) => region.displayLabel).toSet())
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.place_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
          ],
  );
}

String guideApplicationLabel(String? status) => switch (status) {
  'approved' => '답변 참여 승인됨',
  'pending' => '답변자 신청 검토 중',
  'rejected' => '답변자 신청 결과 확인 필요',
  'suspended' => '답변 참여 일시 중지',
  null => '답변자 신청 전',
  _ => '답변 참여 상태 확인 필요',
};

class AssignedGuideCard extends StatelessWidget {
  const AssignedGuideCard({super.key, required this.guide});
  final AssignedGuideSummary guide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('이 질문의 로컬 가이드', style: secondaryStyle),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  foregroundColor: theme.colorScheme.onSurface,
                  child: const Icon(Icons.person_outline_rounded),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(guide.name, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text('채택된 답변 ${guide.acceptedAnswerCount}건'),
                      const SizedBox(height: 4),
                      Text(
                        guideApplicationLabel(guide.applicationStatus),
                        style: secondaryStyle,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 32),
            Text('등록한 활동 지역', style: theme.textTheme.labelLarge),
            const SizedBox(height: 10),
            GuideRegionList(regions: guide.activityRegions),
            const SizedBox(height: 6),
            Text(
              '채택 건수는 답변 활동 기록입니다. 참여 승인과 등록 지역은 전문성 인증을 의미하지 않습니다.',
              style: secondaryStyle,
            ),
          ],
        ),
      ),
    );
  }
}
