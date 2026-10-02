import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/formatters.dart';
import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/empty_state.dart';
import 'profile_repository.dart';

class PointHistoryPage extends ConsumerWidget {
  const PointHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transactions = ref.watch(pointTransactionsProvider);
    return AppPage(
      title: '가상 포인트 내역',
      actions: [
        IconButton(
          tooltip: '새로고침',
          onPressed: () => ref.invalidate(pointTransactionsProvider),
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: AsyncValueView(
        value: transactions,
        data: (items) {
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.receipt_long_outlined,
              title: '포인트 내역이 없습니다',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final tx = items[index];
              final positive = tx.amount > 0;
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: positive
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.secondaryContainer,
                    child: Icon(positive ? Icons.add : Icons.remove),
                  ),
                  title: Text(_label(tx.type)),
                  subtitle: Text(formatDate(tx.createdAt)),
                  trailing: Text(
                    formatPoints(tx.amount),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: positive
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.secondary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _label(String type) {
    return switch (type) {
      'charge_mock' => '가상 포인트 지급',
      'hold' => '질문 보상 보류',
      'reward' => '답변 보상',
      'refund' => '가상 포인트 반환',
      'penalty' => '패널티',
      'admin_adjustment' => '관리자 조정',
      _ => type,
    };
  }
}
