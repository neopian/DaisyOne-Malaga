import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/auth_repository.dart';
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
            if (context.mounted) {
              router.go('/auth');
            }
          },
        ),
      ],
    );
  }
}
