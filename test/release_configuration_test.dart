import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/core/constants/app_config.dart';

void main() {
  String? check(
    String url, {
    bool isWeb = false,
    bool isRelease = true,
    bool demoMode = false,
    bool devLogin = false,
  }) => nativeReleaseConfigurationError(
    isWeb: isWeb,
    isRelease: isRelease,
    demoMode: demoMode,
    enableDevLogin: devLogin,
    apiUrl: url,
  );
  test(
    'native release rejects missing, plaintext or credential-bearing API',
    () {
      for (final url in [
        '',
        '/api',
        'http://host.example/api',
        'https://localhost/api',
        'https://user:secret@host.example/api',
        'https://host.example/api?token=x',
      ]) {
        expect(check(url), isNotNull, reason: url);
      }
      expect(check('https://host.example/api'), isNull);
    },
  );
  test('native release rejects development accounts and demo data', () {
    expect(check('https://host.example/api', demoMode: true), isNotNull);
    expect(check('https://host.example/api', devLogin: true), isNotNull);
  });
  test('authorized web preview and local development remain usable', () {
    expect(check('/api', isWeb: true, demoMode: true, devLogin: true), isNull);
    expect(check('http://localhost:8080/api', isRelease: false), isNull);
  });
}
