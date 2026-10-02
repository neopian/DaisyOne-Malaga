import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_config.dart';
import 'router.dart';
import 'theme.dart';

class ConciergeApp extends ConsumerWidget {
  const ConciergeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configError = AppConfig.configurationError;
    if (configError != null) {
      return MaterialApp(
        theme: buildAppTheme(),
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  '$configError\n새 앱 버전이 준비되면 다시 설치해주세요.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      );
    }
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'malaga · 현지의 답',
      theme: buildAppTheme(),
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      builder: (context, child) => AppConfig.demoMode
          ? Column(
              children: [
                Material(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: Text(
                          '브라우저 전용 데모 · 가상 포인트 · 실제 결제 없음 · 기기 간 동기화 없음',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                                fontSize: 11,
                              ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(child: child ?? const SizedBox.shrink()),
              ],
            )
          : child ?? const SizedBox.shrink(),
    );
  }
}
