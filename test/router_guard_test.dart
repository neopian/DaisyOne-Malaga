import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/app/router.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';

void main() {
  const user = AppUser(
    id: 'user',
    email: 'user@example.com',
    name: '사용자',
    pointBalance: 1000,
    isAdmin: false,
  );
  const admin = AppUser(
    id: 'admin',
    email: 'admin@example.com',
    name: '관리자',
    pointBalance: 1000,
    isAdmin: true,
  );
  test('private deep links wait for bounded session restoration', () {
    expect(
      authRedirect(initialized: false, user: null, location: '/questions/q1'),
      '/',
    );
    expect(authRedirect(initialized: false, user: null, location: '/'), isNull);
  });
  test('expired session is redirected away from all private routes', () {
    for (final route in [
      '/home',
      '/questions/new',
      '/questions/q1',
      '/answers/new/q1',
      '/profile',
      '/points',
      '/helper/apply',
      '/admin/helpers',
    ]) {
      expect(
        authRedirect(initialized: true, user: null, location: route),
        '/auth',
      );
    }
    expect(
      authRedirect(initialized: true, user: null, location: '/auth'),
      isNull,
    );
  });
  test('signed-in user cannot open admin deep links', () {
    expect(
      authRedirect(initialized: true, user: user, location: '/admin'),
      '/home',
    );
    expect(
      authRedirect(initialized: true, user: user, location: '/admin/helpers'),
      '/home',
    );
    expect(
      authRedirect(initialized: true, user: admin, location: '/admin/helpers'),
      isNull,
    );
    expect(
      authRedirect(initialized: true, user: user, location: '/profile'),
      isNull,
    );
    expect(
      authRedirect(initialized: true, user: user, location: '/auth'),
      '/home',
    );
  });
}
