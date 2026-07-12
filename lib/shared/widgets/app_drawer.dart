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

    return NavigationDrawer(
      children: [
        const SizedBox(height: 20),
        ListTile(
          leading: const Icon(Icons.home_outlined),
          title: const Text('홈'),
          onTap: () {
            Navigator.of(context).pop();
            router.go('/home');
          },
        ),
        ListTile(
          leading: const Icon(Icons.receipt_long_outlined),
          title: const Text('포인트 내역'),
          onTap: () => router.go('/points'),
        ),
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: const Text('내 프로필'),
          onTap: () => router.go('/profile'),
        ),
        if (profile?.isAdmin ?? false)
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('관리자'),
            onTap: () => router.go('/admin'),
          ),
        _ProfileSummary(
          profileAsync: profileAsync,
          onRetry: () => ref.invalidate(currentProfileProvider),
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('로그아웃'),
          onTap: () async {
            await ref.read(authRepositoryProvider).signOut();
            invalidateSessionScopedProviders(ref);
            if (context.mounted) {
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
      leading: const SizedBox(width: 24),
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
              Text(profile.email),
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
                  Text(
                    '남은 포인트 ${formatPoints(profile.pointBalance)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w700,
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
