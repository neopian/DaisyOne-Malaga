import 'package:flutter/material.dart';

import '../../shared/models/question.dart';
import 'travel_question_support.dart';

/// A text-only recovery list, independent of GPS, map bounds and image loading.
class TravelRecoveryQuestions extends StatelessWidget {
  const TravelRecoveryQuestions({
    super.key,
    required this.questions,
    required this.ownerId,
    required this.onOpen,
  });

  final Future<List<Question>> questions;
  final String ownerId;
  final ValueChanged<Question> onOpen;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Question>>(
    future: questions,
    builder: (context, snapshot) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      if (snapshot.connectionState != ConnectionState.done) {
        return Semantics(
          liveRegion: true,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('최근 내 질문을 확인하고 있어요…'),
          ),
        );
      }
      if (snapshot.hasError) {
        return Semantics(
          liveRegion: true,
          child: Text(
            '질문 목록을 불러오지 못했어요. 연결을 확인한 뒤 다시 확인해주세요. 이전 요청은 취소되지 않았습니다.',
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
          ),
        );
      }
      final ownQuestions = snapshot.data!
          .where((question) => question.userId == ownerId)
          .take(10)
          .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('최근 내 질문', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final question in ownQuestions)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(question.title),
                  subtitle: Text(travelCityLabel(question.city)),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  onTap: () => onOpen(question),
                ),
              ),
            ),
          Text(
            ownQuestions.isEmpty
                ? '불러온 목록에서 내 질문을 찾지 못했어요. 목록에 없다고 등록 실패가 확정되는 것은 아닙니다.'
                : '최근 불러온 내 질문을 최대 10개 표시합니다. 목록에 없어도 이전 요청이 처리 중일 수 있어요.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
        ],
      );
    },
  );
}
