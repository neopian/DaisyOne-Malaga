import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/shared/widgets/location_input_section.dart';

void main() {
  testWidgets('현재 위치 전용 모드에서는 수동 변경 버튼을 숨긴다', (tester) async {
    final country = TextEditingController(text: 'Spain');
    final city = TextEditingController(text: 'Malaga');
    addTearDown(country.dispose);
    addTearDown(city.dispose);
    var refreshCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocationInputSection(
            countryController: country,
            cityController: city,
            isEditing: false,
            isLoading: false,
            allowManualEdit: false,
            onEdit: () => fail('수동 변경을 호출하면 안 됩니다.'),
            onDone: () {},
            onUseCurrentLocation: () => refreshCount += 1,
          ),
        ),
      ),
    );

    expect(find.text('변경'), findsNothing);
    expect(find.byTooltip('현재 위치 새로고침'), findsOneWidget);

    await tester.tap(find.byTooltip('현재 위치 새로고침'));
    expect(refreshCount, 1);
  });
}
