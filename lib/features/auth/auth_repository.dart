import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../shared/models/app_user.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(supabaseClientProvider));
});

final authStateProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(authRepositoryProvider).authStateChanges;
});

class AuthRepository {
  const AuthRepository(this._client);

  final SupabaseClient _client;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;
  User? get currentUser => _client.auth.currentUser;

  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String name,
  }) async {
    final response = await _client.auth.signUp(
      email: email,
      password: password,
      data: {'name': name},
    );
    final user = response.user;
    if (user != null && response.session != null) {
      await ensureProfile(user: user, fallbackName: name);
    }
    return response;
  }

  Future<void> signIn({required String email, required String password}) async {
    final response = await _client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    final user = response.user;
    if (user != null) {
      await ensureProfile(user: user);
    }
  }

  Future<void> signOut() => _client.auth.signOut();

  Future<AppUser> ensureCurrentProfile() async {
    final user = currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다.');
    }
    return ensureProfile(user: user);
  }

  Future<AppUser> ensureProfile({
    required User user,
    String? fallbackName,
  }) async {
    final row = await _client
        .from('users')
        .select()
        .eq('id', user.id)
        .maybeSingle();

    if (row != null) {
      return AppUser.fromMap(Map<String, dynamic>.from(row));
    }

    final email = user.email ?? '';
    final nameFromMeta = user.userMetadata?['name'] as String?;
    final name = (fallbackName ?? nameFromMeta ?? email.split('@').first)
        .trim();

    final profile = {
      'id': user.id,
      'email': email,
      'name': name.isEmpty ? '사용자' : name,
      'point_balance': 1000,
    };

    await _client.from('users').insert(profile);
    await _client.from('point_transactions').insert({
      'user_id': user.id,
      'type': 'charge_mock',
      'amount': 1000,
    });

    final created = await _client
        .from('users')
        .select()
        .eq('id', user.id)
        .single();
    return AppUser.fromMap(Map<String, dynamic>.from(created));
  }
}
