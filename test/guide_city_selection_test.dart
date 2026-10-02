import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/features/helper_application/helper_application_page.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';

void main() {
  testWidgets(
    'guide picks canonical Europe and US cities locally without duplicate regions',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentProfileProvider.overrideWith(
              (_) async => const AppUser(
                id: 'guide',
                email: 'guide@example.test',
                name: '가이드',
                pointBalance: 1000,
                isAdmin: false,
              ),
            ),
          ],
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const HelperApplicationPage(),
          ),
        ),
      );
      Future<void> choose(String query) async {
        await tester.ensureVisible(
          find.byKey(const ValueKey('guide-city-select')),
        );
        await tester.tap(find.byKey(const ValueKey('guide-city-select')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('travel-city-search')),
          query,
        );
        await tester.pump();
        await tester.tap(find.byType(ListTile).last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('지역 추가'));
        await tester.tap(find.text('지역 추가'));
        await tester.pumpAndSettle();
      }

      await choose('뉴욕');
      await choose('France');
      await choose('Paris');
      expect(find.byType(InputChip), findsNWidgets(2));
      expect(find.text('미국 · 뉴욕'), findsOneWidget);
      expect(find.text('프랑스 · 파리'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
