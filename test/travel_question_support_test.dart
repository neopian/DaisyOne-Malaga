import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/core/constants/app_constants.dart';
import 'package:local_qa_concierge/core/geo/city_catalog.g.dart';
import 'package:local_qa_concierge/features/questions/travel_question_support.dart';

void main() {
  test('all manual options use catalog city centers without live lookups', () {
    for (final city in CityCatalog.knownPlaces) {
      final location = locationForTravelCity(city);
      expect(location.country, city.country);
      expect(location.city, city.city);
      expect(
        CityCatalog.isSupportedLocation(location.country, location.city),
        isTrue,
      );
      expect(travelCityLabel(city.city), contains(city.city));
    }
  });

  test(
    'travel starters use existing categories and request facts rather than supply them',
    () {
      expect(travelQuestionStarters.length, 4);
      for (final starter in travelQuestionStarters) {
        expect(AppConstants.categories, contains(starter.category));
        expect(starter.category, isNot('긴급도움'));
        expect(starter.title.length, greaterThanOrEqualTo(4));
        expect(starter.body, contains('알려주세요'));
        expect(starter.body, isNot(contains('분 안에')));
      }
      expect(travelQuestionStarters.first.body, contains('현지 시각'));
      expect(travelQuestionStarters.first.body, contains('인원·짐'));
      expect(travelQuestionStarters[1].body, contains('방문 날짜'));
    },
  );

  test(
    'denied, outside-city and unavailable GPS all explain a manual alternative',
    () {
      expect(
        travelLocationError(StateError('위치 권한이 필요합니다.')),
        contains('권한 없이도'),
      );
      expect(
        travelLocationError(StateError('선택 가능한 도시에서 멀리 떨어져 있습니다.')),
        contains('여행지 밖에 있어도'),
      );
      expect(travelLocationError(Exception('offline')), contains('도시를 선택'));
    },
  );
}
