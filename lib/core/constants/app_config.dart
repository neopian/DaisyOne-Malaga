import 'package:flutter/foundation.dart';

class AppConfig {
  static const _configuredApiUrl = String.fromEnvironment('API_BASE_URL');
  static const demoMode = bool.fromEnvironment('DEMO_MODE');
  static const enableDevLogin = bool.fromEnvironment('ENABLE_DEV_LOGIN');
  static const privacyPolicyUrl = String.fromEnvironment('PRIVACY_POLICY_URL');
  static const supportUrl = String.fromEnvironment('SUPPORT_URL');
  static const supportEmail = String.fromEnvironment('SUPPORT_EMAIL');
  static const termsUrl = String.fromEnvironment('TERMS_URL');
  static const communityGuidelinesUrl = String.fromEnvironment(
    'COMMUNITY_GUIDELINES_URL',
  );

  static String? get configurationError => nativeReleaseConfigurationError(
    isWeb: kIsWeb,
    isRelease: kReleaseMode,
    demoMode: demoMode,
    enableDevLogin: enableDevLogin,
    apiUrl: _configuredApiUrl,
  );

  /// Web previews use the same origin, so tokens never go to a third-party API.
  static String get apiBaseUrl => _configuredApiUrl.isNotEmpty
      ? (kIsWeb
            ? Uri.base.resolve(_configuredApiUrl).toString()
            : _configuredApiUrl)
      : (kIsWeb
            ? Uri.base.resolve('/api').toString()
            : 'http://localhost:8080/api');
}

String? nativeReleaseConfigurationError({
  required bool isWeb,
  required bool isRelease,
  required bool demoMode,
  required bool enableDevLogin,
  required String apiUrl,
}) {
  if (isWeb || !isRelease) return null;
  if (demoMode || enableDevLogin) return '배포용 앱에 개발 설정이 포함되어 있습니다.';
  final uri = Uri.tryParse(apiUrl);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.host == 'localhost' ||
      uri.host.endsWith('.localhost')) {
    return '배포용 서버 연결 설정을 확인해야 합니다.';
  }
  return null;
}
