import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../admin/admin_repository.dart';
import '../helper_application/helper_repository.dart';
import '../profile/profile_repository.dart';
import '../questions/question_repository.dart';
import '../safety/safety_repository.dart';

void invalidateSessionScopedProviders(WidgetRef ref) {
  ref.invalidate(blockedUsersProvider);
  ref.invalidate(moderationReportsProvider);
  ref.invalidate(currentProfileProvider);
  ref.invalidate(pointTransactionsProvider);
  ref.invalidate(helperApplicationProvider);
  ref.invalidate(helperRegionsProvider);
  ref.invalidate(guideSummaryProvider);
  ref.invalidate(questionsProvider);
  ref.invalidate(helperOpenQuestionsProvider);
  ref.invalidate(questionProvider);
  ref.invalidate(pendingHelperApplicationsProvider);
}

/// Non-widget counterpart used by the router's synchronous auth listener.
void invalidateSessionScopedProvidersForRef(Ref ref) {
  ref.invalidate(blockedUsersProvider);
  ref.invalidate(moderationReportsProvider);
  ref.invalidate(currentProfileProvider);
  ref.invalidate(pointTransactionsProvider);
  ref.invalidate(helperApplicationProvider);
  ref.invalidate(helperRegionsProvider);
  ref.invalidate(guideSummaryProvider);
  ref.invalidate(questionsProvider);
  ref.invalidate(helperOpenQuestionsProvider);
  ref.invalidate(questionProvider);
  ref.invalidate(pendingHelperApplicationsProvider);
}
