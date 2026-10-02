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
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.verified_user_outlined),
                        const SizedBox(width: 10),
                        Text(
                          '신청 상태',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const Spacer(),
                        StatusChip(
                          label: data.status,
                          emphasis: data.isApproved,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(data.introduction),
                    const SizedBox(height: 16),
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
