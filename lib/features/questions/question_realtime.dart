import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../profile/profile_repository.dart';
import 'question_repository.dart';

final questionRealtimeProvider = Provider.autoDispose<void>((ref) {
  final client = ref.watch(supabaseClientProvider);
  Timer? refreshTimer;

  void refreshQuestions() {
    refreshTimer?.cancel();
    refreshTimer = Timer(const Duration(milliseconds: 250), () {
      ref.invalidate(questionsProvider);
      ref.invalidate(helperOpenQuestionsProvider);
      ref.invalidate(questionProvider);
      ref.invalidate(currentProfileProvider);
    });
  }

  final channel = client
      .channel('question-workflow')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'questions',
        callback: (_) => refreshQuestions(),
      )
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'answers',
        callback: (_) => refreshQuestions(),
      )
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'question_comments',
        callback: (_) => refreshQuestions(),
      )
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'question_images',
        callback: (_) => refreshQuestions(),
      )
      .subscribe((status, _) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          refreshQuestions();
        }
      });
  final syncTimer = Timer.periodic(
    const Duration(seconds: 15),
    (_) => refreshQuestions(),
  );

  ref.onDispose(() {
    refreshTimer?.cancel();
    syncTimer.cancel();
    unawaited(client.removeChannel(channel));
  });
});
