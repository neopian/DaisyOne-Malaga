import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../geo/city_catalog.g.dart';

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

      final city = CityCatalog.nearestSupported(
        latitude: position.latitude,
        longitude: position.longitude,
      );
      if (city == null) {
        throw StateError('선택 가능한 도시에서 멀리 떨어져 있습니다. 여행할 도시를 직접 선택해주세요.');
      }
      // This is a nearby catalog association, not reverse-geocoded territory or
      // a promise of guide availability. Manual city selection always works.
      return DeviceLocation(
        country: city.country,
        city: city.city,
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } on MissingPluginException {
      throw StateError('위치 기능 적용을 위해 앱을 완전히 종료한 뒤 다시 실행해 주세요.');
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError('현재 위치를 자동으로 확인하지 못했습니다. 위치 권한과 위치 서비스를 확인해주세요.');
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
}
