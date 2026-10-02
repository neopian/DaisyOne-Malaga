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
        onRetry: () => ref.invalidate(currentProfileProvider),
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
                  leading: const Icon(Icons.pending_actions_outlined),
                  title: const Text('응답 대기 현황'),
                  subtitle: const Text('지역별 미응답 질문과 진행이 막힌 상태를 확인합니다'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/admin/operations'),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.assignment_outlined),
                  title: const Text('진행 문제 검토'),
                  subtitle: const Text('참여자가 남긴 비공개 진행 기록을 확인합니다'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/admin/exchange-issues'),
                ),
              ),
              const SizedBox(height: 8),
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
