import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/admin/admin_helper_applications_page.dart';
import '../features/admin/admin_home_page.dart';
import '../features/answers/answer_form_page.dart';
import '../features/auth/auth_page.dart';
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
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const SplashPage()),
      GoRoute(path: '/auth', builder: (context, state) => const AuthPage()),
      GoRoute(
        path: '/home',
        builder: (context, state) => const QuestionHomePage(),
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
});
