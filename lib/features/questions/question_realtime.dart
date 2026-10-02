import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_repository.dart';
import '../guide_discovery/guide_discovery_feed.dart';
import '../helper_application/helper_repository.dart';
import '../profile/profile_repository.dart';
import '../activity/activity_feed.dart';
import 'question_repository.dart';

/// Shared by visible question pages. Stops in background and on disposal.
final questionRealtimeProvider = Provider.autoDispose<void>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  void refresh() {
    if (auth.currentUser == null) return;
    ref.invalidate(activityRefreshProvider);
    ref.invalidate(guideDiscoveryRefreshProvider);
    ref.invalidate(questionsProvider);
    ref.invalidate(helperOpenQuestionsProvider);
    ref.invalidate(questionProvider);
    ref.invalidate(currentProfileProvider);
    ref.invalidate(pointTransactionsProvider);
    ref.invalidate(helperApplicationProvider);
    ref.invalidate(guideSummaryProvider);
  }

  final observer = ForegroundPoller(refresh);
  WidgetsBinding.instance.addObserver(observer);
  observer.start(WidgetsBinding.instance.lifecycleState);
  ref.onDispose(() {
    observer.dispose();
    WidgetsBinding.instance.removeObserver(observer);
  });
});

class ForegroundPoller extends WidgetsBindingObserver {
  ForegroundPoller(this.refresh, {this.interval = const Duration(seconds: 15)});
  final VoidCallback refresh;
  final Duration interval;
  Timer? _timer;
  bool get isRunning => _timer?.isActive ?? false;
  void start(AppLifecycleState? state) {
    _timer?.cancel();
    if (state == null || state == AppLifecycleState.resumed) {
      _timer = Timer.periodic(interval, (_) => refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    start(state);
    if (state == AppLifecycleState.resumed) refresh();
  }

  void dispose() {
    _timer?.cancel();
  }
}
