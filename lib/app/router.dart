import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../shared/models/app_user.dart';
import '../features/activity/activity_page.dart';
import '../features/activity/activity_repository.dart';
import '../features/admin/admin_helper_applications_page.dart';
import '../features/admin/admin_home_page.dart';
import '../features/admin/admin_reports_page.dart';
import '../features/admin/operations_page.dart';
import '../features/exchange_issues/exchange_issues_page.dart';
import '../features/account/account_settings_page.dart';
import '../features/auth/password_recovery_page.dart';
import '../features/auth/email_verification_page.dart';
import '../features/safety/blocked_users_page.dart';
import '../features/safety/app_info_page.dart';
import '../features/answers/answer_form_page.dart';
import '../features/auth/auth_page.dart';
import '../features/auth/auth_repository.dart';
import '../features/auth/session_scope.dart';
import '../features/auth/splash_page.dart';
import '../features/helper_application/helper_application_page.dart';
import '../features/helper_application/helper_home_page.dart';
import '../features/helper_application/helper_waiting_page.dart';
import '../features/profile/point_history_page.dart';
import '../features/profile/profile_page.dart';
import '../features/questions/create_question_page.dart';
import '../features/questions/question_detail_page.dart';
import '../features/questions/question_home_page.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  Object accountScope() => (
    auth.currentUser?.id,
    auth.currentUser?.isAdmin,
    auth.currentUser?.isSuspended,
  );
  var scope = accountScope();
  void onSessionChange() {
    if (scope == accountScope()) return;
    scope = accountScope();
    invalidateSessionScopedProvidersForRef(ref);
  }

  auth.addListener(onSessionChange);
  ref.onDispose(() => auth.removeListener(onSessionChange));
  final router = GoRouter(
    refreshListenable: auth,
    redirect: (context, state) {
      return authRedirect(
        initialized: auth.initialized,
        user: auth.currentUser,
        location: state.matchedLocation,
      );
    },
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const SplashPage()),
      GoRoute(path: '/auth', builder: (context, state) => const AuthPage()),
      GoRoute(
        path: '/auth/recovery',
        builder: (context, state) => const PasswordRecoveryPage(),
      ),
      GoRoute(path: '/about', builder: (context, state) => const AppInfoPage()),
      GoRoute(
        path: '/account',
        builder: (context, state) => const AccountSettingsPage(),
      ),
      GoRoute(
        path: '/account/verify',
        builder: (context, state) => const EmailVerificationPage(),
      ),
      GoRoute(
        path: '/account/blocked',
        builder: (context, state) => const BlockedUsersPage(),
      ),
      GoRoute(
        path: '/account/exchange-issues',
        builder: (context, state) => ExchangeIssuesPage(
          questionId: state.uri.queryParameters['question'],
        ),
      ),
      GoRoute(
        path: '/admin/exchange-issues',
        builder: (context, state) => const ExchangeIssuesPage(admin: true),
      ),
      GoRoute(
        path: '/admin/operations',
        builder: (context, state) => const OperationsPage(),
      ),
      GoRoute(
        path: '/admin/reports',
        builder: (context, state) => const AdminReportsPage(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const QuestionHomePage(),
      ),
      GoRoute(
        path: '/activity/traveler',
        builder: (context, state) =>
            const ActivityPage(role: ActivityRole.traveler),
      ),
      GoRoute(
        path: '/activity/guide',
        builder: (context, state) =>
            const ActivityPage(role: ActivityRole.guide),
      ),
      GoRoute(
        path: '/questions/new',
        builder: (context, state) => const CreateQuestionPage(),
      ),
      GoRoute(
        path: '/questions/:id',
        builder: (context, state) =>
            QuestionDetailPage(questionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/answers/new/:questionId',
        builder: (context, state) =>
            AnswerFormPage(questionId: state.pathParameters['questionId']!),
      ),
      GoRoute(
        path: '/helper/apply',
        builder: (context, state) => const HelperApplicationPage(),
      ),
      GoRoute(
        path: '/helper/waiting',
        builder: (context, state) => const HelperWaitingPage(),
      ),
      GoRoute(
        path: '/helper/home',
        builder: (context, state) => const HelperHomePage(),
      ),
      GoRoute(
        path: '/profile',
        builder: (context, state) => const ProfilePage(),
      ),
      GoRoute(
        path: '/points',
        builder: (context, state) => const PointHistoryPage(),
      ),
      GoRoute(
        path: '/admin',
        builder: (context, state) => const AdminHomePage(),
      ),
      GoRoute(
        path: '/admin/helpers',
        builder: (context, state) => const AdminHelperApplicationsPage(),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

String? authRedirect({
  required bool initialized,
  required AppUser? user,
  required String location,
}) {
  if (!initialized) return location == '/' ? null : '/';
  if (user == null) {
    return const ['/auth', '/auth/recovery', '/about'].contains(location)
        ? null
        : '/auth';
  }
  if (user.isSuspended &&
      !location.startsWith('/account') &&
      !const ['/about', '/profile', '/points'].contains(location)) {
    return '/account';
  }
  if (location == '/auth' || location == '/') return '/home';
  if (location.startsWith('/admin') && !user.isAdmin) return '/home';
  return null;
}
