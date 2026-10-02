import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../admin/admin_repository.dart';
import '../admin/operations_feed.dart';
import '../exchange_issues/exchange_issue_feed.dart';
import '../activity/activity_feed.dart';
import '../guide_discovery/guide_discovery_feed.dart';
import '../helper_application/helper_repository.dart';
import '../profile/profile_repository.dart';
import '../questions/question_repository.dart';
import '../safety/safety_repository.dart';

void invalidateSessionScopedProviders(WidgetRef ref) {
  ref.invalidate(exchangeIssueFeedProvider);
  ref.invalidate(operationsFeedProvider);
  ref.invalidate(activityFeedProvider);
  ref.invalidate(guideDiscoveryFeedProvider);
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
  ref.invalidate(exchangeIssueFeedProvider);
  ref.invalidate(operationsFeedProvider);
  ref.invalidate(activityFeedProvider);
  ref.invalidate(guideDiscoveryFeedProvider);
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
