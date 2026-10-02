import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_config.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(baseUrl: AppConfig.apiBaseUrl);
  ref.onDispose(client.dispose);
  return client;
});

class ApiException implements Exception {
  const ApiException(this.message, {this.code = 'request_failed', this.status});
  final String message;
  final String code;
  final int? status;
  @override
  String toString() => message;
}

/// JSON transport with bounded requests and durable retry keys. The database is
/// the authority for identity, permissions, balances, and all workflow changes.
class ApiClient {
  ApiClient({
    required String baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
    Future<SharedPreferences> Function()? preferences,
  }) : baseUri = Uri.parse('${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/'),
       _http = client ?? http.Client(),
       _preferences = preferences ?? SharedPreferences.getInstance;

  final Uri baseUri;
  final http.Client _http;
  final Duration timeout;
  final Future<SharedPreferences> Function() _preferences;
  final _pendingKeys = <String, String>{};
  final _inFlight = <String, Future<Object?>>{};
  String? token;
  String? userId;
  Future<void> Function()? onUnauthorized;

  Future<Object?> get(String path) => _request('GET', path);

  Future<Map<String, dynamic>> getMap(String path) async =>
      asMap(await get(path));

  Future<List<Map<String, dynamic>>> getList(String path) async {
    final value = await get(path);
    if (value is! List) throw const ApiException('서버 응답 형식을 확인해주세요.');
    return value.map(asMap).toList();
  }

  /// Retrying an identical unacknowledged operation reuses its key, including
  /// after a reload. Concurrent taps share the same request. Passwords and
  /// request payloads are never written to preferences.
  Future<Object?> mutate(
    String path, {
    Map<String, dynamic>? body,
    String method = 'POST',
    bool authenticated = true,
    String? idempotencyKey,
  }) {
    if (idempotencyKey != null &&
        !RegExp(r'^[A-Za-z0-9_.:-]{8,128}$').hasMatch(idempotencyKey)) {
      return Future<Object?>.error(
        const ApiException('요청 식별자를 확인해주세요.', code: 'invalid_idempotency_key'),
      );
    }
    if (authenticated && token == null) {
      return Future<Object?>.error(
        const ApiException('로그인이 필요합니다.', code: 'unauthorized', status: 401),
      );
    }
    final encoded = jsonEncode(body ?? <String, dynamic>{});
    final fingerprint = sha256
        .convert(
          utf8.encode(
            '$baseUri|${userId ?? 'anonymous'}|$method|$path|$encoded'
            '${idempotencyKey == null ? '' : '|request:$idempotencyKey'}',
          ),
        )
        .toString();
    final existing = _inFlight[fingerprint];
    if (existing != null) return existing;
    final result = _mutation(
      method,
      path,
      encoded,
      fingerprint,
      authenticated: authenticated,
      expectedToken: token,
      idempotencyKey: idempotencyKey,
    );
    _inFlight[fingerprint] = result;
    return result.whenComplete(() => _inFlight.remove(fingerprint));
  }

  Future<Object?> _mutation(
    String method,
    String path,
    String body,
    String fingerprint, {
    required bool authenticated,
    required String? expectedToken,
    String? idempotencyKey,
  }) async {
    // Authentication and account reauthentication contain secrets. Even a
    // plain hash of that body would be an offline password-checking artifact,
    // so their retry lookup and opaque keys stay in memory only. Ordinary
    // question/answer mutations retain durable retry keys across reloads.
    final durable =
        authenticated &&
        !path.startsWith('auth/') &&
        !path.startsWith('account/');
    final storageKey = 'api.pending.$fingerprint';
    final SharedPreferences? prefs;
    try {
      prefs = durable ? await _preferences().timeout(timeout) : null;
    } catch (_) {
      throw const ApiException(
        '재시도 정보를 불러올 수 없습니다. 저장 공간을 확인해주세요.',
        code: 'storage',
      );
    }
    final key = _pendingKeys.putIfAbsent(
      fingerprint,
      () => idempotencyKey ?? prefs?.getString(storageKey) ?? _newKey(),
    );
    try {
      if (prefs != null &&
          !await prefs.setString(storageKey, key).timeout(timeout)) {
        throw const ApiException(
          '재시도 정보를 저장할 수 없습니다. 저장 공간을 확인해주세요.',
          code: 'storage',
        );
      }
    } catch (_) {
      throw const ApiException(
        '재시도 정보를 저장할 수 없습니다. 저장 공간을 확인해주세요.',
        code: 'storage',
      );
    }
    try {
      final result = await _request(
        method,
        path,
        body: body,
        idempotencyKey: key,
        authenticated: authenticated,
        expectedToken: expectedToken,
      );
      // Cleanup is best-effort after a server acknowledgement. A storage
      // failure must not turn a completed debit into an apparent failed call.
      try {
        await prefs?.remove(storageKey).timeout(timeout);
      } catch (_) {
        /* A retained key safely replays the prior result. */
      }
      _pendingKeys.remove(fingerprint);
      return result;
    } on ApiException catch (error) {
      // Unknown outcomes retain the key. A 401 on a durable operation may
      // precede replay lookup for a previously committed request: reauth must
      // not turn that retry into a second question or point hold. An HTTP 408
      // from an intermediary is also uncertain, like a local response timeout.
      if ((!durable && error.code == 'AUTH_RETRY_EXPIRED') ||
          (error.status != null &&
              error.status! >= 400 &&
              error.status! < 500 &&
              error.status != 408 &&
              error.status != 429 &&
              error.status != 409 &&
              !(durable && error.status == 401))) {
        _pendingKeys.remove(fingerprint);
        try {
          await prefs?.remove(storageKey).timeout(timeout);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<Object?> _request(
    String method,
    String path, {
    String? body,
    String? idempotencyKey,
    bool authenticated = true,
    String? expectedToken,
  }) async {
    if (authenticated && expectedToken != null && expectedToken != token) {
      throw const ApiException(
        '로그인 정보가 변경되었습니다. 다시 시도해주세요.',
        code: 'session_changed',
      );
    }
    if (authenticated && token == null) {
      throw const ApiException(
        '로그인이 필요합니다.',
        code: 'unauthorized',
        status: 401,
      );
    }
    final requestToken = token;
    try {
      final request = http.Request(method, baseUri.resolve(path))
        ..headers['Accept'] = 'application/json';
      if (authenticated) {
        request.headers['Authorization'] = 'Bearer $requestToken';
      }
      if (idempotencyKey != null) {
        request.headers['Idempotency-Key'] = idempotencyKey;
      }
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = body;
      }
      final response = await _http
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
      if (response.statusCode == 401 &&
          authenticated &&
          token == requestToken) {
        await onUnauthorized?.call();
      }
      Object? decoded;
      try {
        decoded = response.body.isEmpty
            ? null
            : jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        throw ApiException(
          '서버 응답을 읽을 수 없습니다. 잠시 후 다시 시도해주세요.',
          status: response.statusCode,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = decoded is Map ? decoded['error'] : null;
        final code = error is Map
            ? error['code']?.toString() ?? 'request_failed'
            : 'request_failed';
        throw ApiException(
          apiErrorMessage(
            code,
            error is Map ? error['message']?.toString() : null,
          ),
          code: code,
          status: response.statusCode,
        );
      }
      // A previous account's response may arrive after sign-out or account change.
      if (authenticated && token != requestToken) {
        throw const ApiException(
          '로그인 정보가 변경되었습니다. 다시 시도해주세요.',
          code: 'session_changed',
        );
      }
      return decoded;
    } on TimeoutException {
      throw const ApiException(
        '서버 응답이 지연되고 있습니다. 다시 시도해도 같은 요청은 한 번만 처리됩니다.',
        code: 'timeout',
      );
    } on http.ClientException {
      throw const ApiException(
        '서버에 연결할 수 없습니다. 네트워크와 API 주소를 확인해주세요.',
        code: 'connection',
      );
    }
  }

  static Map<String, dynamic> asMap(Object? value) {
    if (value is! Map) throw const ApiException('서버 응답 형식을 확인해주세요.');
    return Map<String, dynamic>.from(value);
  }

  String resolveMediaUrl(String path) => baseUri.resolve(path).toString();

  static String _newKey() {
    final random = Random.secure();
    return List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void dispose() => _http.close();
}

/// Keep backend codes for diagnostics while giving the Korean UI actionable text.
String apiErrorMessage(String code, [String? serverMessage]) {
  const messages = {
    'INSUFFICIENT_POINTS': '보상 포인트가 잔액보다 큽니다. 포인트 내역을 확인해주세요.',
    'QUESTION_UNAVAILABLE': '이미 수락되었거나 종료된 질문입니다. 새로고침해주세요.',
    'REGION_MISMATCH': '신청한 활동 지역에 해당하는 질문만 수락할 수 있습니다.',
    'CANNOT_CANCEL': '아직 답변자가 수락하지 않은 내 질문만 취소할 수 있습니다.',
    'CANNOT_ACCEPT': '이 답변을 채택할 수 없습니다. 질문 상태를 새로고침해주세요.',
    'INVALID_CREDENTIALS': '이메일 또는 비밀번호를 확인해주세요.',
    'UNAUTHENTICATED': '로그인 시간이 만료되었습니다. 다시 로그인해주세요.',
    'EMAIL_EXISTS': '이미 가입된 이메일입니다. 로그인해주세요.',
    'AUTH_RETRY_EXPIRED': '이전 로그인 요청이 만료되었습니다. 다시 로그인해주세요.',
    'HELPER_NOT_APPROVED': '승인된 답변자만 질문을 수락하고 답변할 수 있습니다.',
    'SELF_ANSWER': '내가 작성한 질문은 답변자로 수락할 수 없습니다.',
    'ANSWER_ALREADY_SUBMITTED': '이미 답변이 제출되었습니다. 질문 상세를 새로고침해주세요.',
    'APPLICATION_EXISTS': '이미 신청한 내역이 있습니다. 답변자 상태를 확인해주세요.',
    'QUESTION_CLOSED': '종료된 질문입니다. 질문 상태를 새로고침해주세요.',
    'QUESTION_EXPIRED': '질문의 유효 시간이 지났습니다. 질문 상태를 새로고침해주세요.',
    'EVIDENCE_REQUIRED': '확인할 수 있는 근거 URL을 한 개 이상 추가해주세요.',
    'INVALID_EVIDENCE_URL':
        '공개 웹사이트의 http 또는 https 주소를 입력해주세요. 로컬·IP 주소나 공백·로그인 정보가 있는 URL은 사용할 수 없습니다.',
    'INVALID_IMAGE':
        'JPG·PNG·WebP 정지 사진만 첨부할 수 있습니다. 장당 3MiB·2,000만 화소 이하의 사진을 선택해주세요. 처리 후 용량이 크면 더 작은 사진을 사용해주세요.',
    'IMAGE_PROCESSING_BUSY': '사진을 처리하는 요청이 많습니다. 잠시 후 다시 등록해주세요.',
    'INVALID_IMAGE_TOKEN': '사진 링크가 만료되었습니다. 질문을 새로고침해주세요.',
    'PAYLOAD_TOO_LARGE': '첨부 용량이 너무 큽니다. 사진은 최대 5장, 장당 3MB까지 가능합니다.',
    'ADMIN_REQUIRED': '관리자 권한이 필요합니다.',
    'FORBIDDEN': '이 작업을 수행할 권한이 없습니다.',
    'NOT_FOUND': '요청한 내용을 찾을 수 없습니다. 목록을 새로고침해주세요.',
    'RATE_LIMIT': '요청이 너무 많습니다. 잠시 후 다시 시도해주세요.',
    'REQUEST_IN_PROGRESS': '같은 요청을 처리 중입니다. 잠시 후 다시 확인해주세요.',
    'IDEMPOTENCY_CONFLICT': '이전 요청과 내용이 다릅니다. 처리 결과를 먼저 확인해주세요.',
    'VALIDATION': '입력값을 확인해주세요. 필수 항목과 입력 길이를 확인해 주세요.',
    'INVALID_REVIEW': '신청 상태와 거절 사유를 확인해주세요.',
    'INTERNAL_ERROR': '서버에서 요청을 완료하지 못했습니다. 잠시 후 다시 확인해주세요.',
    'CONFLICT': '다른 요청으로 상태가 변경되었습니다. 새로고침해주세요.',
    'CONTENT_REJECTED': '게시할 수 없는 내용이 포함되어 있습니다. 이용 기준에 맞게 내용을 수정해주세요.',
    'ACCOUNT_SUSPENDED': '계정 이용이 정지되었습니다. 계정 설정에서 내 데이터와 계정 삭제에 접근할 수 있습니다.',
    'SELF_REPORT': '내가 작성한 콘텐츠는 신고할 수 없습니다.',
    'SELF_BLOCK': '내 계정은 차단할 수 없습니다.',
    'REPORT_LIMIT': '신고가 많습니다. 잠시 후 다시 시도해주세요.',
    'BLOCK_LIMIT': '차단 목록이 가득 찼습니다. 계정 설정에서 목록을 확인해주세요.',
    'PROTECTED_ACCOUNT': '이 계정의 권한은 운영자가 별도로 검토해야 합니다.',
    'EMAIL_VERIFICATION_REQUIRED':
        '이메일 인증이 필요합니다. 계정 · 개인정보에서 이메일을 확인한 뒤 다시 시도해주세요.',
  };
  if (serverMessage != null && RegExp(r'[가-힣]').hasMatch(serverMessage)) {
    return serverMessage;
  }
  return messages[code.toUpperCase()] ?? '요청을 처리하지 못했습니다. 새로고침한 뒤 다시 시도해주세요.';
}
