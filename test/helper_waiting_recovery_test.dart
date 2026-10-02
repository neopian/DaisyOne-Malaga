import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/features/helper_application/helper_repository.dart';
import 'package:local_qa_concierge/features/helper_application/helper_waiting_page.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/features/questions/question_realtime.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:local_qa_concierge/shared/models/helper_application.dart';

Future<void> _mount(
  WidgetTester tester, {
  String? status = 'rejected',
  String? reason = '활동 지역에서의 경험을 더 자세히 적어주세요.',
  bool largeText = false,
}) async {
  tester.view.physicalSize = Size(largeText ? 320 : 390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/helper/waiting',
    routes: [
      GoRoute(
        path: '/helper/waiting',
        builder: (_, _) => const HelperWaitingPage(),
      ),
      GoRoute(
        path: '/helper/apply',
        builder: (_, _) => const Scaffold(body: Text('새 신청서')),
      ),
      GoRoute(
        path: '/helper/home',
        builder: (_, _) => const Scaffold(body: Text('가이드 홈 화면')),
      ),
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('여행자 홈 화면')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        questionRealtimeProvider.overrideWith((ref) {}),
        currentProfileProvider.overrideWith(
          (ref) async => const AppUser(
            id: 'guide',
            email: 'guide@example.test',
            name: '가이드',
            pointBalance: 1000,
            isAdmin: false,
          ),
        ),
        helperApplicationProvider.overrideWith(
          (ref) async => status == null
              ? null
              : HelperApplication(
                  id: 'application',
                  userId: 'guide',
                  status: status,
                  languages: const ['한국어'],
                  introduction: '말라가에 거주하며 여행을 도와요.',
                  experienceDescription: '말라가 교통과 음식점을 안내한 경험이 있습니다.',
                  rejectReason: reason,
                ),
        ),
      ],
      child: MaterialApp.router(
        theme: buildAppTheme(),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(largeText ? 2 : 1)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('반려 사유와 다시 신청하기를 제공하고 신청서로 이동한다', (tester) async {
    await _mount(tester);
    expect(find.text('반려됨'), findsOneWidget);
    expect(find.text('반려 사유'), findsOneWidget);
    expect(find.text('활동 지역에서의 경험을 더 자세히 적어주세요.'), findsOneWidget);
    await tester.tap(find.text('다시 신청하기'));
    await tester.pumpAndSettle();
    expect(find.text('새 신청서'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('기록된 반려 사유가 없어도 다시 신청할 수 있다', (tester) async {
    await _mount(tester, reason: '  ');
    expect(find.text('안내된 반려 사유가 없습니다.'), findsOneWidget);
    expect(find.text('다시 신청하기'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('활동 정지는 사유를 표시하며 재신청을 제공하지 않는다', (tester) async {
    await _mount(
      tester,
      status: 'suspended',
      reason: '운영 규칙 위반으로 활동이 정지되었습니다.',
    );
    expect(find.text('활동 정지'), findsOneWidget);
    expect(find.text('정지 사유'), findsOneWidget);
    expect(find.text('운영 규칙 위반으로 활동이 정지되었습니다.'), findsOneWidget);
    expect(find.text('다시 신청하기'), findsNothing);
    expect(find.text('답변자 홈'), findsNothing);
    await tester.tap(find.text('질문자 홈'));
    await tester.pumpAndSettle();
    expect(find.text('여행자 홈 화면'), findsOneWidget);
  });

  testWidgets('검토 중에는 재신청을 제공하지 않는다', (tester) async {
    await _mount(tester, status: 'pending');
    expect(find.text('검토 중'), findsOneWidget);
    expect(find.text('반려 사유'), findsNothing);
    expect(find.text('다시 신청하기'), findsNothing);
  });

  testWidgets('승인되면 답변자 홈으로 이동한다', (tester) async {
    await _mount(tester, status: 'approved');
    expect(find.text('승인됨'), findsOneWidget);
    expect(find.text('다시 신청하기'), findsNothing);
    await tester.tap(find.text('답변자 홈'));
    await tester.pumpAndSettle();
    expect(find.text('가이드 홈 화면'), findsOneWidget);
  });

  testWidgets('아직 신청하지 않았으면 신규 신청을 제공한다', (tester) async {
    await _mount(tester, status: null);
    await tester.tap(find.text('답변자 신청'));
    await tester.pumpAndSettle();
    expect(find.text('새 신청서'), findsOneWidget);
  });

  testWidgets('320px 두 배 글자와 긴 반려 사유에서도 재신청에 도달한다', (tester) async {
    final reason = List.filled(20, '활동 지역에서의 경험을 더 자세히 적어주세요.').join(' ');
    await _mount(tester, reason: reason, largeText: true);
    expect(tester.takeException(), isNull);
    expect(find.text(reason), findsOneWidget);
    await tester.scrollUntilVisible(find.text('다시 신청하기'), 500, maxScrolls: 80);
    await tester.tap(find.text('다시 신청하기'));
    await tester.pumpAndSettle();
    expect(find.text('새 신청서'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
