import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_config.dart';
import 'auth_repository.dart';
import 'session_scope.dart';

const _devLoginPassword = 'daisy-dev-1234';
const _showLoginShortcuts =
    AppConfig.enableDevLogin || bool.fromEnvironment('ENABLE_LOGIN_SHORTCUTS');

const _devLoginAccounts = [
  _DevLoginAccount(
    label: '질문자1',
    email: 'questioner1@example.com',
    name: '질문자1',
    icon: Icons.person_outline,
  ),
  _DevLoginAccount(
    label: '질문자2',
    email: 'questioner2@example.com',
    name: '질문자2',
    icon: Icons.person_outline,
  ),
  _DevLoginAccount(
    label: '질문자3',
    email: 'questioner3@example.com',
    name: '질문자3',
    icon: Icons.person_outline,
  ),
  _DevLoginAccount(
    label: '답변자1',
    email: 'answerer1@example.com',
    name: '답변자1',
    icon: Icons.support_agent,
  ),
  _DevLoginAccount(
    label: '답변자2',
    email: 'answerer2@example.com',
    name: '답변자2',
    icon: Icons.support_agent,
  ),
];

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  static const _rememberedEmailKey = 'auth.remembered_email';

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _isSignUp = false;
  bool _isLoading = false;
  bool _rememberMe = false;
  bool _rememberChoiceEdited = false;
  bool _passwordVisible = false;

  @override
  void initState() {
    super.initState();
    _loadRememberedEmail();
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadRememberedEmail() async {
    try {
      final preferences = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      final rememberedEmail = preferences.getString(_rememberedEmailKey);
      if (!mounted || rememberedEmail == null || rememberedEmail.isEmpty) {
        return;
      }
      setState(() {
        if (_email.text.isEmpty) _email.text = rememberedEmail;
        if (!_rememberChoiceEdited) _rememberMe = true;
      });
    } catch (_) {
      // Optional remembered email never blocks a fresh login.
    }
  }

  Future<void> _submit() async {
    if (_isLoading || !_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      final repo = ref.read(authRepositoryProvider);
      if (_isSignUp) {
        await repo.signUp(
          email: _email.text.trim(),
          password: _password.text,
          name: _name.text.trim(),
          rememberMe: false,
        );
      } else {
        await repo.signIn(
          email: _email.text.trim(),
          password: _password.text,
          rememberMe: _rememberMe,
        );
        await _saveRememberedEmail();
      }
      if (mounted) invalidateSessionScopedProviders(ref);
      if (mounted) router.go('/home');
    } catch (error) {
      if (mounted && messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(_authErrorText(error))));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signInWithShortcut(_DevLoginAccount account) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _isSignUp = false;
      _email.text = account.email;
      _password.text = _devLoginPassword;
    });

    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref
          .read(authRepositoryProvider)
          .signIn(
            email: account.email,
            password: _devLoginPassword,
            rememberMe: _rememberMe,
          );
      await _saveRememberedEmail();
      if (mounted) invalidateSessionScopedProviders(ref);
      if (mounted) router.go('/home');
    } catch (error) {
      if (mounted && messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(_authErrorText(error))));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _retryRestoration() async {
    if (_isLoading) return;
    final repository = ref.read(authRepositoryProvider);
    final router = GoRouter.of(context);
    setState(() => _isLoading = true);
    try {
      await repository.retryRestoreSession();
      if (mounted && repository.currentUser != null) {
        invalidateSessionScopedProviders(ref);
        router.go('/home');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _authErrorText(Object error) {
    final message = error.toString();
    return message;
  }

  Future<void> _saveRememberedEmail() async {
    if (!mounted) return;
    final email = _email.text.trim();
    final remember = _rememberMe;
    final repository = ref.read(authRepositoryProvider);
    final owner = repository.currentUser?.id;
    try {
      final preferences = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      if (!mounted || repository.currentUser?.id != owner) return;
      if (remember) {
        await preferences
            .setString(_rememberedEmailKey, email)
            .timeout(const Duration(seconds: 5));
      } else {
        await preferences
            .remove(_rememberedEmailKey)
            .timeout(const Duration(seconds: 5));
      }
    } catch (_) {
      // Email autofill is optional and cannot turn a successful login into an
      // apparent failure or touch a disposed controller after navigation.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authRepositoryProvider);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) {
            final wide = viewport.maxWidth >= 880;
            final form = Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(28),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: EdgeInsets.all(wide ? 32 : 24),
                child: _buildForm(auth),
              ),
            );
            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: wide ? 48 : 20,
                vertical: wide ? 40 : 32,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (viewport.maxHeight - (wide ? 80 : 64)).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Expanded(child: _WelcomeHeader(wide: true)),
                              const SizedBox(width: 72),
                              Expanded(child: form),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const _WelcomeHeader(wide: false),
                              const SizedBox(height: 28),
                              form,
                            ],
                          ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildForm(AuthRepository auth) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _isSignUp ? '계정 만들기' : '로그인',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            _isSignUp ? '여행자와 현지 가이드가 만나는 곳.' : '나의 질문과 답변을 이어가세요.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 28),
          ListenableBuilder(
            listenable: auth,
            builder: (context, _) {
              if (auth.restorationError == null && !auth.isRestoring) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      auth.isRestoring
                          ? '이전 로그인을 확인하고 있습니다…'
                          : auth.restorationError!,
                      textAlign: TextAlign.center,
                    ),
                    if (auth.canRetryRestoration || auth.isRestoring) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _isLoading || auth.isRestoring
                            ? null
                            : _retryRestoration,
                        icon: const Icon(Icons.refresh),
                        label: const Text('이전 로그인 다시 확인'),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
          if (_isSignUp) ...[
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '이름',
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: (value) => value == null || value.trim().length < 2
                  ? '이름을 입력해주세요.'
                  : null,
            ),
            const SizedBox(height: 12),
          ],
          TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '이메일',
              prefixIcon: Icon(Icons.mail_outline),
            ),
            validator: (value) =>
                value == null || !value.contains('@') ? '이메일을 입력해주세요.' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _password,
            obscureText: !_passwordVisible,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) {
              if (!_isLoading) _submit();
            },
            decoration: InputDecoration(
              suffixIcon: IconButton(
                tooltip: _passwordVisible ? '비밀번호 숨기기' : '비밀번호 보기',
                onPressed: () =>
                    setState(() => _passwordVisible = !_passwordVisible),
                icon: Icon(
                  _passwordVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
              labelText: '비밀번호',
              prefixIcon: Icon(Icons.lock_outline),
            ),
            validator: (value) =>
                value == null || value.length < 8 ? '8자 이상 입력해주세요.' : null,
          ),
          if (!_isSignUp) ...[
            const SizedBox(height: 10),
            CheckboxListTile(
              value: _rememberMe,
              onChanged: _isLoading
                  ? null
                  : (value) {
                      setState(() {
                        _rememberChoiceEdited = true;
                        _rememberMe = value ?? false;
                      });
                    },
              title: const Text('로그인 정보 기억하기'),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              visualDensity: VisualDensity.compact,
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _isLoading ? null : _submit,
            icon: _isLoading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_isSignUp ? Icons.person_add : Icons.login),
            label: Text(_isSignUp ? '가입하기' : '로그인'),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: _isLoading
                ? null
                : () => setState(() => _isSignUp = !_isSignUp),
            child: Text(_isSignUp ? '이미 계정이 있어요' : '새 계정 만들기'),
          ),
          if (!_isSignUp)
            TextButton(
              onPressed: _isLoading
                  ? null
                  : () => context.push('/auth/recovery'),
              child: const Text('비밀번호를 잊으셨나요?'),
            ),
          TextButton(
            onPressed: _isLoading ? null : () => context.push('/about'),
            child: const Text('개인정보 · 이용 안내'),
          ),
          if (!_isSignUp && _showLoginShortcuts) ...[
            const Divider(height: 36),
            Text(
              '테스트 계정으로 둘러보기',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final account in _devLoginAccounts)
                  OutlinedButton.icon(
                    onPressed: _isLoading
                        ? null
                        : () => _signInWithShortcut(account),
                    icon: Icon(account.icon, size: 18),
                    label: Text(account.label),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(112, 48),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _WelcomeHeader extends StatelessWidget {
  const _WelcomeHeader({required this.wide});
  final bool wide;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(
                Icons.explore_outlined,
                color: Colors.white,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '여행 Q&A',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.5,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: wide ? 40 : 24),
        Text(
          '여행의 질문을\n현지의 답으로.',
          style:
              (wide
                      ? theme.textTheme.headlineLarge
                      : theme.textTheme.headlineMedium)
                  ?.copyWith(fontSize: wide ? 44 : 30, letterSpacing: -1.2),
        ),
        const SizedBox(height: 16),
        Text(
          '낯선 곳에서 궁금한 순간,\n현지 가이드에게 가볍게 물어보세요.',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (wide) ...[
          const SizedBox(height: 36),
          Row(
            children: [
              Icon(
                Icons.place_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text('유럽과 미국, 현지에 물어보세요', style: theme.textTheme.bodyMedium),
            ],
          ),
        ],
      ],
    );
  }
}

class _DevLoginAccount {
  const _DevLoginAccount({
    required this.label,
    required this.email,
    required this.name,
    required this.icon,
  });

  final String label;
  final String email;
  final String name;
  final IconData icon;
}
