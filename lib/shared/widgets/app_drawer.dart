import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/formatters.dart';
import '../../features/auth/auth_repository.dart';
import '../../features/auth/session_scope.dart';
import '../../features/profile/profile_repository.dart';
import '../models/app_user.dart';

class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(currentProfileProvider);
    final profile = profileAsync.asData?.value;
    final router = GoRouter.of(context);

    void open(String path) {
      Navigator.of(context).pop();
      router.go(path);
    }

    return NavigationDrawer(
      children: [
        const SizedBox(height: 28),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Icon(
                Icons.explore_outlined,
                color: Theme.of(context).colorScheme.primary,
                size: 28,
              ),
              const SizedBox(width: 10),
              Text(
                'malaga',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _ProfileSummary(
          profileAsync: profileAsync,
          onRetry: () => ref.invalidate(currentProfileProvider),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Divider(),
        ),
        ListTile(
          leading: const Icon(Icons.home_outlined),
          title: const Text('홈'),
          onTap: () => open('/home'),
        ),
        ListTile(
          leading: const Icon(Icons.edit_note_outlined),
          title: const Text('질문하기'),
          onTap: () => open('/questions/new'),
        ),
        ListTile(
          leading: const Icon(Icons.support_agent_outlined),
          title: const Text('로컬 가이드'),
          onTap: () => open('/helper/home'),
        ),
        ListTile(
          leading: const Icon(Icons.receipt_long_outlined),
          title: const Text('포인트 내역'),
          onTap: () => open('/points'),
        ),
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: const Text('내 프로필'),
          onTap: () => open('/profile'),
        ),
        if (profile?.isAdmin ?? false)
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('관리자'),
            onTap: () => open('/admin'),
          ),
        ListTile(
          leading: const Icon(Icons.manage_accounts_outlined),
          title: const Text('계정 · 개인정보'),
          onTap: () => open('/account'),
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('이용 안내'),
          onTap: () => open('/about'),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Divider(),
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('로그아웃'),
          onTap: () async {
            final auth = ref.read(authRepositoryProvider);
            final messenger = ScaffoldMessenger.of(context);
            String? notice;
            try {
              await auth.signOut();
            } catch (error) {
              notice = auth.sessionStorageCleared
                  ? '이 기기의 로그인 정보를 지웠습니다. 서버 로그아웃은 확인하지 못했습니다. 연결을 확인해주세요.'
                  : '로그인 화면으로 이동했지만 저장된 로그인 정보와 서버 로그아웃을 확인하지 못했습니다. 연결과 기기 저장 공간을 확인해주세요.';
            }
            if (!auth.sessionStorageCleared) {
              notice ??=
                  '서버에서 로그아웃했습니다. 이 기기의 저장된 로그인 정보를 지우지 못했으니 저장 공간을 확인해주세요.';
            }
            if (auth.currentUser == null &&
                notice != null &&
                messenger.mounted) {
              messenger.showSnackBar(SnackBar(content: Text(notice)));
            }
            if (context.mounted) {
              invalidateSessionScopedProviders(ref);
              router.go('/auth');
            }
          },
        ),
      ],
    );
  }
}

class _ProfileSummary extends StatelessWidget {
  const _ProfileSummary({required this.profileAsync, required this.onRetry});

  final AsyncValue<AppUser> profileAsync;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      minVerticalPadding: 0,
      visualDensity: VisualDensity.compact,
      title: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: profileAsync.when(
          data: (profile) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profile.name,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                profile.email,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '남은 포인트 ${formatPoints(profile.pointBalance)}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: LinearProgressIndicator(),
          ),
          error: (error, stackTrace) => TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('프로필 정보 다시 불러오기'),
          ),
        ),
      ),
    );
  }
}
