import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../geo/spain_geo.dart';

class DeviceLocation {
  const DeviceLocation({
    required this.country,
    required this.city,
    required this.latitude,
    required this.longitude,
    this.regionName,
  });

  final String country;
  final String city;
  final double latitude;
  final double longitude;
  final String? regionName;

  bool get hasCity => country.trim().isNotEmpty && city.trim().isNotEmpty;

  String get label {
    final region = regionName == null || regionName!.trim().isEmpty
        ? ''
        : ' · ${regionName!.trim()}';
    return '$country $city$region'.trim();
  }
}

class DeviceCoordinates {
  const DeviceCoordinates({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

class LocationService {
  const LocationService();

  Future<DeviceCoordinates> getCurrentCoordinates() async {
    try {
      final position = await _getCurrentPosition();
      if (!SpainGeo.isWithinSpainBounds(
        latitude: position.latitude,
        longitude: position.longitude,
      )) {
        throw StateError('현재 위치가 스페인 밖입니다. 스페인 지역만 표시할 수 있습니다.');
      }
      return DeviceCoordinates(
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } on MissingPluginException {
      throw StateError('위치 기능 적용을 위해 앱을 완전히 종료한 뒤 다시 실행해 주세요.');
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError('현재 위치를 확인하지 못했습니다.');
    }
  }

  Future<DeviceLocation> getCurrentLocation() async {
    try {
      final position = await _getCurrentPosition();

      if (!SpainGeo.isWithinSpainBounds(
        latitude: position.latitude,
        longitude: position.longitude,
      )) {
        throw StateError('현재 위치가 스페인 밖입니다. 스페인 지역만 질문할 수 있습니다.');
      }

      if (kIsWeb) {
        final place = SpainGeo.nearestPlace(
          latitude: position.latitude,
          longitude: position.longitude,
        );
        return DeviceLocation(
          country: 'Spain',
          city: place.city,
          latitude: position.latitude,
          longitude: position.longitude,
        );
      }

      final places = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      ).timeout(const Duration(seconds: 12));

      if (places.isEmpty) {
        throw StateError('현재 위치의 주소를 찾지 못했습니다.');
      }

      final place = places.first;
      final country = (place.country ?? '').trim();
      if (!SpainGeo.isSpainCountry(country)) {
        throw StateError('현재 위치가 스페인 밖입니다. 스페인 지역만 질문할 수 있습니다.');
      }

      final city = _firstNonEmpty([
        place.locality,
        place.subAdministrativeArea,
        place.administrativeArea,
      ]);
      final region = _firstNonEmpty([
        place.subLocality,
        place.thoroughfare,
        place.name,
      ]);

      if (country.isEmpty || city.isEmpty) {
        throw StateError('현재 위치의 국가/도시를 확인하지 못했습니다.');
      }

      return DeviceLocation(
        country: 'Spain',
        city: city,
        latitude: position.latitude,
        longitude: position.longitude,
        regionName: region.isEmpty ? null : region,
      );
    } on MissingPluginException {
      throw StateError('위치 기능 적용을 위해 앱을 완전히 종료한 뒤 다시 실행해 주세요.');
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError('현재 위치를 자동으로 확인하지 못했습니다. 스페인 도시를 직접 입력해주세요.');
    }
  }

  Future<Position> _getCurrentPosition() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      throw StateError('기기 위치 서비스가 꺼져 있습니다.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('위치 권한이 필요합니다.');
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 12),
      ),
    );
  }

  static String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }
}
