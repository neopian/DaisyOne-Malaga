import 'dart:math' as math;

class SpainGeo {
  static const defaultLatitude = 40.4168;
  static const defaultLongitude = -3.7038;

  static const minLatitude = 27.5;
  static const maxLatitude = 44.4;
  static const minLongitude = -18.4;
  static const maxLongitude = 4.5;

  static bool isSpainCountry(String country) {
    final normalized = country.trim().toLowerCase();
    return normalized == 'spain' ||
        normalized == 'españa' ||
        normalized == 'espana' ||
        normalized == 'es';
  }

  static bool isWithinSpainBounds({
    required double latitude,
    required double longitude,
  }) {
    return latitude >= minLatitude &&
        latitude <= maxLatitude &&
        longitude >= minLongitude &&
        longitude <= maxLongitude;
  }

  static SpainPlace nearestPlace({
    required double latitude,
    required double longitude,
  }) {
    var nearest = knownPlaces.first;
    var nearestDistance = double.infinity;
    for (final place in knownPlaces) {
      final distance = _distanceSquared(
        latitude,
        longitude,
        place.latitude,
        place.longitude,
      );
      if (distance < nearestDistance) {
        nearest = place;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  static SpainPlace placeForCity(String city) {
    final normalized = _normalize(city);
    for (final place in knownPlaces) {
      if (_normalize(place.city) == normalized ||
          place.aliases.any((alias) => _normalize(alias) == normalized)) {
        return place;
      }
    }
    return const SpainPlace(
      city: 'Madrid',
      latitude: defaultLatitude,
      longitude: defaultLongitude,
    );
  }

  static double _distanceSquared(
    double latitudeA,
    double longitudeA,
    double latitudeB,
    double longitudeB,
  ) {
    final latitudeDelta = latitudeA - latitudeB;
    final longitudeDelta =
        (longitudeA - longitudeB) *
        math.cos((latitudeA + latitudeB) * math.pi / 360);
    return latitudeDelta * latitudeDelta + longitudeDelta * longitudeDelta;
  }

  static String _normalize(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ñ', 'n');
  }

  static const knownPlaces = [
    SpainPlace(city: 'Madrid', latitude: 40.4168, longitude: -3.7038),
    SpainPlace(city: 'Barcelona', latitude: 41.3874, longitude: 2.1686),
    SpainPlace(city: 'Valencia', latitude: 39.4699, longitude: -0.3763),
    SpainPlace(city: 'Sevilla', latitude: 37.3891, longitude: -5.9845),
    SpainPlace(city: 'Zaragoza', latitude: 41.6488, longitude: -0.8891),
    SpainPlace(city: 'Málaga', latitude: 36.7213, longitude: -4.4214),
    SpainPlace(city: 'Murcia', latitude: 37.9922, longitude: -1.1307),
    SpainPlace(city: 'Palma', latitude: 39.5696, longitude: 2.6502),
    SpainPlace(
      city: 'Las Palmas de Gran Canaria',
      latitude: 28.1235,
      longitude: -15.4363,
      aliases: ['Las Palmas'],
    ),
    SpainPlace(city: 'Bilbao', latitude: 43.2630, longitude: -2.9350),
    SpainPlace(city: 'Alicante', latitude: 38.3452, longitude: -0.4810),
    SpainPlace(city: 'Córdoba', latitude: 37.8882, longitude: -4.7794),
    SpainPlace(city: 'Valladolid', latitude: 41.6523, longitude: -4.7245),
    SpainPlace(city: 'Vigo', latitude: 42.2406, longitude: -8.7207),
    SpainPlace(city: 'Gijón', latitude: 43.5322, longitude: -5.6611),
    SpainPlace(city: 'A Coruña', latitude: 43.3623, longitude: -8.4115),
    SpainPlace(city: 'Granada', latitude: 37.1773, longitude: -3.5986),
    SpainPlace(city: 'Oviedo', latitude: 43.3619, longitude: -5.8494),
    SpainPlace(city: 'Santander', latitude: 43.4623, longitude: -3.8099),
    SpainPlace(city: 'Toledo', latitude: 39.8628, longitude: -4.0273),
  ];
}

class SpainPlace {
  const SpainPlace({
    required this.city,
    required this.latitude,
    required this.longitude,
    this.aliases = const [],
  });

  final String city;
  final double latitude;
  final double longitude;
  final List<String> aliases;
}
