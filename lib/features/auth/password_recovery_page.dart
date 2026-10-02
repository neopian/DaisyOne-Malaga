import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'account_flow_widgets.dart';
import 'auth_repository.dart';

class PasswordRecoveryPage extends ConsumerStatefulWidget {
  const PasswordRecoveryPage({super.key});

  @override
  ConsumerState<PasswordRecoveryPage> createState() =>
      _PasswordRecoveryPageState();
}

class _PasswordRecoveryPageState extends ConsumerState<PasswordRecoveryPage> {
  final _requestForm = GlobalKey<FormState>();
  final _resetForm = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _token = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _busy = false;
  bool _complete = false;
  bool _visible = false;
  String? _notice;
  bool _error = false;
  String? _demoToken;

  @override
  void dispose() {
    _email.dispose();
    _token.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    if (_busy || !_requestForm.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _notice = null;
      _demoToken = null;
    });
    try {
      final result = await ref
          .read(authRepositoryProvider)
          .requestPasswordReset(_email.text);
      if (!mounted) return;
      setState(() {
        _demoToken = result.demonstrationToken;
        _error = false;
        _notice = result.isDemonstration
            ? '미리보기: 실제 이메일은 전송되지 않습니다. 아래 테스트 코드를 사용할 수 있습니다.'
            : '요청을 접수했습니다. 등록되어 있고 이메일을 받을 수 있는 주소라면 복구 안내가 발송 대기 중입니다. 받은편지함과 스팸함을 확인해주세요.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = true;
          _notice = accountErrorText(error);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    if (_busy || !_resetForm.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .confirmPasswordReset(
            token: accountTokenFromInput(_token.text),
            password: _password.text,
          );
      if (!mounted) return;
      _password.clear();
      _confirmation.clear();
      _token.clear();
      setState(() {
        _complete = true;
        _error = false;
        _notice = '비밀번호를 변경했습니다. 이전 로그인은 만료되었습니다. 새 비밀번호로 로그인해주세요.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = true;
          _notice = accountErrorText(error);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AccountFlowScaffold(
    title: '비밀번호 찾기',
    backFallback: '/auth',
    children: [
      if (_notice != null) ...[
        AccountNotice(_notice!, isError: _error),
        const SizedBox(height: 20),
      ],
      if (_busy) const LinearProgressIndicator(semanticsLabel: '요청 처리 중'),
      if (_complete)
        FilledButton(
          onPressed: () => context.go('/auth'),
          child: const Text('로그인으로 돌아가기'),
        )
      else ...[
        AccountSection(
          children: [
            Text('복구 안내 요청', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('가입할 때 사용한 이메일을 입력해주세요.'),
            const SizedBox(height: 20),
            Form(
              key: _requestForm,
              child: TextFormField(
                controller: _email,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: '이메일'),
                validator: requiredEmail,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _busy ? null : _request,
              child: const Text('복구 이메일 요청'),
            ),
            if (_demoToken != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() => _token.text = _demoToken!),
                child: const Text('미리보기 코드 사용'),
              ),
          ],
        ),
        const SizedBox(height: 20),
        AccountSection(
          children: [
            Text('새 비밀번호 설정', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              '이메일의 인증 코드 또는 링크를 붙여 넣으세요. 이 화면을 닫았다가 다시 열어도 코드를 입력할 수 있습니다.',
            ),
            const SizedBox(height: 20),
            Form(
              key: _resetForm,
              child: Column(
                children: [
                  TextFormField(
                    controller: _token,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(labelText: '인증 코드 또는 링크'),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '인증 코드를 입력해주세요.'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: !_visible,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: InputDecoration(
                      labelText: '새 비밀번호',
                      suffixIcon: IconButton(
                        tooltip: _visible ? '비밀번호 숨기기' : '비밀번호 보기',
                        onPressed: () => setState(() => _visible = !_visible),
                        icon: Icon(
                          _visible
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                    validator: (value) =>
                        (value?.length ?? 0) < 8 ? '8자 이상 입력해주세요.' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _confirmation,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(labelText: '새 비밀번호 확인'),
                    validator: (value) =>
                        value != _password.text || (value?.isEmpty ?? true)
                        ? '비밀번호가 일치하지 않습니다.'
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _reset,
              child: const Text('비밀번호 변경'),
            ),
          ],
        ),
      ],
    ],
  );
}
