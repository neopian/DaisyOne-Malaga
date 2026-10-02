import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/geo/city_catalog.g.dart';
import 'package:local_qa_concierge/shared/widgets/travel_city_picker.dart';

void main() {
  testWidgets(
    'city search accepts Korean and English, then returns the exact country pair',
    (tester) async {
      TravelCity? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  picked = await showTravelCityPicker(context);
                },
                child: const Text('도시 선택'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('도시 선택'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('travel-city-search')),
        '뉴욕',
      );
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.text('미국'), findsOneWidget);
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      expect(picked?.city, 'New York');
      expect(picked?.country, 'United States');
      await tester.tap(find.text('도시 선택'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('travel-city-search')),
        'France',
      );
      await tester.pump();
      expect(find.text('파리 · Paris'), findsOneWidget);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(picked, isNull);
    },
  );

  testWidgets('empty search and close remain usable at 320px and double text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showTravelCityPicker(context),
              child: const Text('도시 선택'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('도시 선택'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('travel-city-search')),
      'Tokyo',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('목록에 없는 도시'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
