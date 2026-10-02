import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/api_service.dart';

String accountErrorText(Object error) {
  if (error is ApiException) {
    return switch (error.code.toUpperCase()) {
      'MAIL_UNAVAILABLE' =>
        '현재 이메일을 보낼 수 없습니다. 이메일은 전송되지 않았습니다. 잠시 후 다시 시도해주세요.',
      'INVALID_OR_EXPIRED_TOKEN' => '인증 코드가 올바르지 않거나 만료되었습니다. 새 코드를 요청해주세요.',
      'EXPORT_TOO_LARGE' =>
        '데이터가 너무 큽니다. 저장된 사진 포함을 해제한 뒤 다시 시도해주세요. 이미 해제했다면 개인정보 · 이용 안내의 문의 방법을 확인해주세요.',
      'REAUTHENTICATION_FAILED' => '현재 비밀번호가 맞지 않습니다. 다시 확인해주세요.',
      'RATE_LIMIT' || 'RATE_LIMITED' => '요청이 많습니다. 잠시 기다린 후 다시 시도해주세요.',
      _ => error.message,
    };
  }
  return '요청을 완료하지 못했습니다. 다시 시도해주세요.';
}

String? requiredEmail(String? value) {
  final email = value?.trim() ?? '';
  return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)
      ? null
      : '올바른 이메일을 입력해주세요.';
}

/// Supports pasting a code or an operator-configured mail link without opening
/// external URLs, changing credentials, or depending on OS link registration.
String accountTokenFromInput(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
    try {
      return Uri.splitQueryString(uri.fragment)['token'] ??
          uri.queryParameters['token'] ??
          trimmed;
    } on FormatException {
      return trimmed;
    }
  }
  return trimmed;
}

class AccountNotice extends StatelessWidget {
  const AccountNotice(this.text, {super.key, this.isError = false});
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isError ? colors.errorContainer : colors.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: isError
                ? colors.onErrorContainer
                : colors.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}

class AccountFlowScaffold extends StatelessWidget {
  const AccountFlowScaffold({
    super.key,
    required this.title,
    required this.children,
    this.backFallback = '/home',
  });
  final String title;
  final String backFallback;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title),
      leading: BackButton(
        onPressed: () {
          final router = GoRouter.maybeOf(context);
          if (router == null) {
            Navigator.maybePop(context);
          } else if (router.canPop()) {
            router.pop();
          } else {
            router.go(backFallback);
          }
        },
      ),
    ),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    ),
  );
}

class AccountSection extends StatelessWidget {
  const AccountSection({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}
