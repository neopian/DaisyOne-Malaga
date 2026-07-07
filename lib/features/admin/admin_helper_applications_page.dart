import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/status_chip.dart';
import 'admin_repository.dart';

class AdminHelperApplicationsPage extends ConsumerWidget {
  const AdminHelperApplicationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final applications = ref.watch(pendingHelperApplicationsProvider);
    return AppPage(
      title: '답변자 신청',
      actions: [
        IconButton(
          tooltip: '새로고침',
          onPressed: () => ref.invalidate(pendingHelperApplicationsProvider),
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: AsyncValueView(
        value: applications,
        data: (items) {
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.verified_user_outlined,
              title: '신청 내역이 없습니다',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final item = items[index];
              return _ApplicationCard(item: item);
            },
          );
        },
      ),
    );
  }
}

class _ApplicationCard extends ConsumerWidget {
  const _ApplicationCard({required this.item});

  final AdminHelperApplication item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = item.application;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    app.languages.join(', '),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                StatusChip(label: app.status, emphasis: app.isApproved),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final region in item.regions)
                  StatusChip(
                    label:
                        '${region.country} ${region.city}${region.regionName == null ? '' : ' · ${region.regionName}'}',
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(app.introduction),
            const SizedBox(height: 8),
            Text(app.experienceDescription),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: app.status == 'rejected'
                        ? null
                        : () => _reject(context, ref, app.id),
                    icon: const Icon(Icons.close),
                    label: const Text('거절'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: app.status == 'approved'
                        ? null
                        : () => _review(context, ref, app.id, 'approved'),
                    icon: const Icon(Icons.check),
                    label: const Text('승인'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _reject(
    BuildContext context,
    WidgetRef ref,
    String applicationId,
  ) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('거절 사유'),
          content: TextField(
            controller: controller,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '사유'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
    if (reason == null) return;
    if (context.mounted) {
      await _review(
        context,
        ref,
        applicationId,
        'rejected',
        rejectReason: reason,
      );
    }
  }

  Future<void> _review(
    BuildContext context,
    WidgetRef ref,
    String applicationId,
    String status, {
    String? rejectReason,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(adminRepositoryProvider)
          .reviewApplication(
            applicationId: applicationId,
            status: status,
            rejectReason: rejectReason,
          );
      ref.invalidate(pendingHelperApplicationsProvider);
      messenger.showSnackBar(SnackBar(content: Text('$status 처리했습니다.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}
