import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/geo/city_catalog.g.dart';
import 'package:local_qa_concierge/features/questions/travel_location_section.dart';
import 'package:local_qa_concierge/features/questions/travel_question_support.dart';

class _OfflineTiles extends TileProvider {
  @override
  ImageProvider getImage(
    TileCoordinates coordinates,
    TileLayer options,
  ) => MemoryImage(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAQAAAAEAAQMAAABmvDolAAAAAXNSR0IB2cksfwAAAAlwSFlzAAALEwAACxMBAJqcGAAAAANQTFRF////p8QbyAAAAB9JREFUeJztwQENAAAAwqD3T20ON6AAAAAAAAAAAL4NIQAAAfFnIe4AAAAASUVORK5CYII=',
    ),
  );
}

void main() {
  testWidgets(
    'optional map only offers catalog city pins and works with offline tiles',
    (tester) async {
      TravelCity? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TravelLocationSection(
                location: locationForTravelCity(
                  CityCatalog.findCity('Spain', 'Madrid')!,
                ),
                isManual: false,
                isLoading: false,
                enabled: true,
                tileProvider: _OfflineTiles(),
                onCitySelected: (city) => selected = city,
                onUseCurrentLocation: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.byType(FlutterMap), findsNothing);
      await tester.tap(find.text('지도에서 도시 선택'));
      await tester.pumpAndSettle();
      expect(find.byType(FlutterMap), findsOneWidget);
      final markers = tester
          .widget<MarkerLayer>(find.byType(MarkerLayer))
          .markers;
      expect(markers.length, CityCatalog.knownPlaces.length);
      expect(find.textContaining('도시 목록으로 선택'), findsOneWidget);
      final madrid = find.byKey(const ValueKey('travel-map-city-Madrid'));
      await tester.ensureVisible(madrid);
      await tester.tap(madrid);
      expect(selected?.city, 'Madrid');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long US city name and unavailable GPS fit a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final city = CityCatalog.knownPlaces.firstWhere(
      (city) => city.city == 'Washington DC',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: TravelLocationSection(
                location: locationForTravelCity(city),
                isManual: true,
                isLoading: false,
                enabled: true,
                errorText: travelLocationError(StateError('위치 권한이 필요합니다.')),
                onCitySelected: (_) {},
                onUseCurrentLocation: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('워싱턴'), findsWidgets);
  });
}
