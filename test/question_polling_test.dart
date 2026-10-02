import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/features/questions/question_realtime.dart';

void main() {
  testWidgets('foreground polling stops in background and on disposal', (
    tester,
  ) async {
    var refreshes = 0;
    final poller = ForegroundPoller(() => refreshes++);
    poller.start(AppLifecycleState.resumed);
    expect(poller.isRunning, isTrue);
    await tester.pump(const Duration(seconds: 14));
    expect(refreshes, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(refreshes, 1);
    poller.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(poller.isRunning, isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(refreshes, 1);
    poller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(refreshes, 2);
    await tester.pump(const Duration(seconds: 15));
    expect(refreshes, 3);
    poller.dispose();
    expect(poller.isRunning, isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(refreshes, 3);
  });
}
