import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo/city_catalog.g.dart';
import '../../core/services/location_service.dart';

/// Injectable only at the service boundary; production uses the device's GPS.
final questionLocationLoaderProvider =
    Provider<Future<DeviceLocation> Function()>(
      (ref) => const LocationService().getCurrentLocation,
    );

class TravelQuestionStarter {
  const TravelQuestionStarter({
    required this.label,
    required this.category,
    required this.title,
    required this.body,
  });

  final String label;
  final String category;
  final String title;
  final String body;
}

/// Prompts for travelers to complete, never claims about live local conditions.
const travelQuestionStarters = [
  TravelQuestionStarter(
    label: '공항 이동',
    category: '교통',
    title: '공항에서 목적지까지 어떻게 이동하나요?',
    body:
        '출발 공항·터미널: \n목적지·가까운 역: \n이동 날짜·현지 시각: \n인원·짐: \n가능한 교통편과 막차·요금을 확인할 공식 링크를 알려주세요.',
  ),
  TravelQuestionStarter(
    label: '영업시간',
    category: '생활',
    title: '방문하려는 곳의 영업시간을 확인하고 싶어요',
    body:
        '장소 이름·주소 또는 지도 링크: \n방문 날짜·현지 시각: \n휴무·입장 마감·예약 필요 여부를 확인할 공식 링크를 알려주세요.',
  ),
  TravelQuestionStarter(
    label: '식당 문의',
    category: '식당',
    title: '식당 메뉴와 요청 방법이 궁금해요',
    body:
        '식당 이름·메뉴: \n원하는 식사 조건·빼고 싶은 재료: \n방문 날짜·현지 시각: \n직원에게 확인할 현지 언어 표현을 알려주세요. 재료와 조리 방식은 식당에 직접 확인하겠습니다.',
  ),
  TravelQuestionStarter(
    label: '현지 언어 도움',
    category: '번역',
    title: '여행 중 사용할 현지 언어 표현이 필요해요',
    body:
        '사용할 장소·상황: \n전하고 싶은 말 또는 읽기 어려운 문구: \n상대에게 보여줄 짧고 공손한 현지 언어와 한국어 뜻을 알려주세요.',
  ),
];

DeviceLocation locationForTravelCity(TravelCity city) => DeviceLocation(
  country: city.country,
  city: city.city,
  latitude: city.latitude,
  longitude: city.longitude,
);

String travelLocationError(Object error) {
  final message = error.toString().replaceFirst('Bad state: ', '').trim();
  if (message.contains('멀리') || message.contains('밖')) {
    return '여행지 밖에 있어도 질문할 수 있어요. 아래에서 유럽·미국의 여행할 도시를 선택해주세요.';
  }
  if (message.contains('권한')) {
    return '위치 권한 없이도 질문할 수 있어요. 아래에서 여행할 도시를 선택해주세요.';
  }
  return '현재 위치를 확인하지 못했어요. 아래에서 도시를 선택하거나 내 위치를 다시 확인해주세요.';
}

String travelCityLabel(String city, {String? country}) {
  final place = country == null
      ? CityCatalog.knownPlaces.where((p) => p.city == city).firstOrNull
      : CityCatalog.findCity(country, city);
  return place == null ? city : '${place.cityKo} · ${place.city}';
}
