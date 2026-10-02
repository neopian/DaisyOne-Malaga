import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/location_service.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/app_user.dart';
import '../../shared/widgets/app_page.dart';
import '../../shared/widgets/guide_activity_card.dart';
import '../helper_application/helper_repository.dart';
import '../questions/question_realtime.dart';
import 'profile_repository.dart';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final _country = TextEditingController();
  final _city = TextEditingController();
  bool _isResolvingLocation = false;
  bool _didSeedProfileLocation = false;
  String? _locationError;

  @override
  void dispose() {
    _country.dispose();
    _city.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    if (_isResolvingLocation) return;
    setState(() {
      _isResolvingLocation = true;
      _locationError = null;
    });
    try {
      final location = await const LocationService().getCurrentLocation();
      await ref
          .read(profileRepositoryProvider)
          .updateLocation(country: location.country, city: location.city);
      if (!mounted) return;
      setState(() {
        _country.text = location.country;
        _city.text = location.city;
      });
      ref.invalidate(currentProfileProvider);
    } catch (error) {
      if (!mounted) return;
      setState(() => _locationError = _locationMessage(error));
    } finally {
      if (mounted) setState(() => _isResolvingLocation = false);
    }
  }

  void _seedProfileLocation(AppUser user) {
    if (_didSeedProfileLocation) return;
    _didSeedProfileLocation = true;
    if (_city.text.trim().isNotEmpty) {
      return;
    }
    _country.text = user.currentCountry ?? '';
    _city.text = user.currentCity ?? '';
  }

  String _locationMessage(Object error) {
    return error.toString().replaceFirst('Bad state: ', '');
  }

  Future<void> _refresh() async {
    ref.invalidate(currentProfileProvider);
    ref.invalidate(guideSummaryProvider);
    await Future.wait([
      ref
          .read(currentProfileProvider.future)
          .then<void>((_) {}, onError: (_, _) {}),
      ref
          .read(guideSummaryProvider.future)
          .then<void>((_) {}, onError: (_, _) {}),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(questionRealtimeProvider);
    final profile = ref.watch(currentProfileProvider);
    final summary = ref.watch(guideSummaryProvider);
    return AppPage(
      title: '내 프로필',
      actions: [
        IconButton(
          tooltip: '새로고침',
          onPressed: _refresh,
          icon: const Icon(Icons.refresh_rounded),
        ),
        const SizedBox(width: 8),
      ],
      body: profile.when(
        loading: () => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(height: 16),
                Text('프로필을 불러오고 있어요'),
              ],
            ),
          ),
        ),
        error: (_, _) => Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.person_outline_rounded,
                    size: 32,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '프로필을 불러오지 못했어요',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '연결을 확인한 뒤 다시 시도해 주세요.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: _refresh, child: const Text('다시 시도')),
                ],
              ),
            ),
          ),
        ),
        data: (user) {
          _seedProfileLocation(user);
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                  children: [
                    _ProfileIdentity(user: user),
                    const SizedBox(height: 16),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.manage_accounts_outlined),
                        title: const Text('계정 · 개인정보'),
                        subtitle: Text(
                          user.isEmailVerified
                              ? '이메일 확인 완료 · 데이터 및 계정 관리'
                              : '이메일 확인 · 데이터 및 계정 관리',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.go('/account'),
                      ),
                    ),
                    const SizedBox(height: 28),
                    _BalanceCard(points: user.pointBalance),
                    const SizedBox(height: 16),
                    GuideActivitySection(
                      value: summary,
                      onRetry: () => ref.invalidate(guideSummaryProvider),
                    ),
                    const SizedBox(height: 16),
                    _ProfileLocation(
                      label: [
                        _country.text.trim(),
                        _city.text.trim(),
                      ].where((part) => part.isNotEmpty).join(' · '),
                      isLoading: _isResolvingLocation,
                      error: _locationError,
                      onRefresh: _useCurrentLocation,
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

class _ProfileIdentity extends StatelessWidget {
  const _ProfileIdentity({required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatar = CircleAvatar(
      radius: 30,
      backgroundColor: theme.colorScheme.surface,
      foregroundColor: theme.colorScheme.onSurface,
      child: Text(
        user.name.isEmpty ? '?' : user.name.characters.first,
        style: theme.textTheme.headlineSmall,
      ),
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(user.name, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          user.email,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 340 ||
            MediaQuery.textScalerOf(context).scale(14) > 18) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [avatar, const SizedBox(height: 16), details],
          );
        }
        return Row(
          children: [
            avatar,
            const SizedBox(width: 18),
            Expanded(child: details),
          ],
        );
      },
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.points});

  final int points;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('내 가상 포인트', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Text(
              formatPoints(points),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -0.8,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '질문과 답변에 사용하는 가상 포인트예요. 현금 가치가 없고 구매·출금할 수 없어요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileLocation extends StatelessWidget {
  const _ProfileLocation({
    required this.label,
    required this.isLoading,
    required this.error,
    required this.onRefresh,
  });

  final String label;
  final bool isLoading;
  final String? error;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('현재 위치', style: theme.textTheme.titleMedium),
                ),
                const SizedBox(width: 8),
                if (isLoading)
                  const SizedBox.square(
                    dimension: 48,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else
                  IconButton(
                    tooltip: '현재 위치 새로고침',
                    onPressed: onRefresh,
                    icon: const Icon(Icons.my_location_outlined),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label.isEmpty
                  ? isLoading
                        ? '위치를 확인하고 있어요'
                        : '위치가 설정되지 않았어요'
                  : label,
              style: theme.textTheme.bodyLarge,
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
