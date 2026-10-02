import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/async_value_view.dart';
import '../profile/profile_repository.dart';

class AdminHomePage extends ConsumerWidget {
  const AdminHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider);
    return AppPage(
      title: '관리자',
      body: AsyncValueView(
        value: profile,
        data: (user) {
          if (!user.isAdmin) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('관리자 권한이 필요합니다.'),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: const Text('답변자 신청 목록'),
                  subtitle: const Text('승인, 거절, 정지 상태를 관리합니다'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/admin/helpers'),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.report_outlined),
                  title: const Text('신고 검토'),
                  subtitle: const Text('콘텐츠와 사용자 신고를 확인하고 조치합니다'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/admin/reports'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
