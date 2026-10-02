import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/status_chip.dart';
import 'helper_repository.dart';
import '../questions/question_realtime.dart';

class HelperWaitingPage extends ConsumerWidget {
  const HelperWaitingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(questionRealtimeProvider);
    final application = ref.watch(helperApplicationProvider);
    return AppPage(
      title: '답변자 상태',
      body: AsyncValueView(
        value: application,
        data: (data) {
          if (data == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: FilledButton.icon(
                  onPressed: () => context.go('/helper/apply'),
                  icon: const Icon(Icons.person_add_alt_outlined),
                  label: const Text('답변자 신청'),
                ),
              ),
            );
          }
          final isRejected = data.status == 'rejected';
          final isSuspended = data.status == 'suspended';
          final reason = data.rejectReason?.trim();
          final statusLabel = switch (data.status) {
            'pending' => '검토 중',
            'approved' => '승인됨',
            'rejected' => '반려됨',
            'suspended' => '활동 정지',
            _ => '상태 확인 필요',
          };
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Icon(Icons.verified_user_outlined),
                        Text(
                          '신청 상태',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        StatusChip(
                          label: statusLabel,
                          emphasis: data.isApproved,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(data.introduction),
                    if (data.isPending) ...[
                      const SizedBox(height: 16),
                      const Text('신청 내용을 검토하고 있어요.'),
                    ],
                    if (isRejected || isSuspended) ...[
                      const Divider(height: 32),
                      Text(
                        isRejected ? '반려 사유' : '정지 사유',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        reason?.isNotEmpty == true
                            ? reason!
                            : isRejected
                            ? '안내된 반려 사유가 없습니다.'
                            : '안내된 정지 사유가 없습니다.',
                      ),
                      const SizedBox(height: 12),
                      Text(
                        isRejected
                            ? '반려 사유를 확인하고 새 신청서를 제출할 수 있어요.'
                            : '답변자 활동이 정지된 상태에서는 다시 신청할 수 없습니다.',
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (isRejected) ...[
                      FilledButton.icon(
                        onPressed: () => context.go('/helper/apply'),
                        icon: const Icon(Icons.edit_note_outlined),
                        label: const Text('다시 신청하기'),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (data.isApproved)
                      FilledButton.icon(
                        onPressed: () => context.go('/helper/home'),
                        icon: const Icon(Icons.support_agent_outlined),
                        label: const Text('답변자 홈'),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: () => context.go('/home'),
                        icon: const Icon(Icons.home_outlined),
                        label: const Text('질문자 홈'),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
