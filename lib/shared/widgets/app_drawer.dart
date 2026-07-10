import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/formatters.dart';
import '../../features/auth/auth_repository.dart';
import '../../features/auth/session_scope.dart';
import '../../features/profile/profile_repository.dart';

class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider).asData?.value;
    final router = GoRouter.of(context);

    return NavigationDrawer(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.travel_explore,
                size: 36,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                profile?.name ?? '현지 Q&A',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(profile?.email ?? ''),
              if (profile != null) ...[
                const SizedBox(height: 10),
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
                      '잔액 ${formatPoints(profile.pointBalance)}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.home_outlined),
          title: const Text('질문자 홈'),
          onTap: () => router.go('/home'),
        ),
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: const Text('내 프로필'),
          onTap: () => router.go('/profile'),
        ),
        ListTile(
          leading: const Icon(Icons.receipt_long_outlined),
          title: const Text('포인트 내역'),
          onTap: () => router.go('/points'),
        ),
        if (profile?.isAdmin ?? false)
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('관리자'),
            onTap: () => router.go('/admin'),
          ),
        const Divider(),
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
