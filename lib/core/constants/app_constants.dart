class AppConstants {
  static const categories = ['교통', '번역', '생활', '쇼핑', '식당', '긴급도움', '기타'];
  static const defaultUrgency = '보통';
  static const urgencies = ['보통', '빠름', '매우 급함'];

  static const sourceTypes = {
    'official': '공식 사이트',
    'map': '지도/영업시간',
    'transport': '교통 사이트',
    'store': '매장/시설',
    'local_info': '현지 정보',
    'other': '기타',
  };

  static const verificationMethods = [
    '공식 사이트에서 확인',
    '지도/영업시간 확인',
    '현지 교통 사이트 확인',
    '매장 공식 페이지 확인',
    '직접 경험 + 현재 사이트 정보 확인',
  ];
}
