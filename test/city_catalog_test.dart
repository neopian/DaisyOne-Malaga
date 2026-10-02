import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/core/geo/city_catalog.g.dart';

void main() {
  test(
    'country and city aliases identify Europe and US choices without conflation',
    () {
      expect(
        CityCatalog.findCity('미국', '뉴욕')?.id,
        CityCatalog.findCity('USA', 'NYC')?.id,
      );
      expect(CityCatalog.findCity('France', '파리')?.city, 'Paris');
      expect(CityCatalog.findCity('España', 'Malaga')?.city, 'Málaga');
      expect(CityCatalog.findCity('United States', 'Paris'), isNull);
      expect(CityCatalog.findCity('Canada', 'London'), isNull);
      expect(CityCatalog.findCity('', 'New York'), isNull);
      expect(CityCatalog.findCity('Japan', 'Tokyo'), isNull);
      expect(CityCatalog.coverageStatus, 'proposed');
      expect(CityCatalog.availabilityGuaranteed, isFalse);
    },
  );

  test(
    'GPS association works on both continents and never silently uses a far city',
    () {
      expect(
        CityCatalog.nearestSupported(
          latitude: 40.7128,
          longitude: -74.0060,
        )?.city,
        'New York',
      );
      expect(
        CityCatalog.nearestSupported(
          latitude: 48.8566,
          longitude: 2.3522,
        )?.city,
        'Paris',
      );
      expect(
        CityCatalog.nearestSupported(latitude: 37.5665, longitude: 126.9780),
        isNull,
      );
      expect(CityCatalog.nearestSupported(latitude: 0, longitude: -35), isNull);
      expect(
        CityCatalog.nearestSupported(latitude: double.nan, longitude: 2),
        isNull,
      );
      expect(CityCatalog.nearestSupported(latitude: 91, longitude: 2), isNull);
    },
  );
}
