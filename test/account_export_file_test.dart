import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/features/account/export_file.dart';
import 'package:local_qa_concierge/features/account/export_file_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const shares = MethodChannel('dev.fluttercommunity.plus/share');
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('account-export-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => temporary.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shares, null);
    await temporary.delete(recursive: true);
  });

  test(
    'interrupted export cleanup removes only owned files and preserves active shares',
    () async {
      final active = await createExportFile(
        'account-export-101.json',
        Uint8List.fromList([123, 125]),
      );
      final abandoned = File(
        '${temporary.path}/account-export/account-export-100.json',
      );
      await abandoned.writeAsString('{}');
      final cache = await Directory('${temporary.path}/share_plus').create();
      final oldCopy = await File(
        '${cache.path}/account-export-99.json',
      ).writeAsString('{}');
      final unrelated = await File(
        '${cache.path}/other-feature.json',
      ).writeAsString('{}');
      await cleanupExportFiles();
      expect(await File(active.path).exists(), isTrue);
      expect(await abandoned.exists(), isFalse);
      expect(await oldCopy.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      final pluginCopy = await File(
        '${cache.path}/account-export-101.json',
      ).writeAsString('{}');
      await removeExportFile(active, 'account-export-101.json');
      expect(await File(active.path).exists(), isFalse);
      expect(
        await pluginCopy.exists(),
        isTrue,
        reason:
            'The Android receiver may still be reading after chooser dismissal.',
      );
      await cleanupExportFiles();
      expect(await pluginCopy.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
    },
  );

  test(
    'share carries JSON with iPad origin and removes original after plugin error',
    () async {
      String? path;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shares, (call) async {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            path = (args['paths'] as List).single as String;
            expect(await File(path!).readAsString(), '{"owner":"a"}');
            expect(args['mimeTypes'], ['application/json']);
            expect(args['originX'], 1.0);
            expect(args['originY'], 2.0);
            throw PlatformException(code: 'cancelled-test');
          });
      await expectLater(
        shareAccountExport('{"owner":"a"}', const Rect.fromLTWH(1, 2, 48, 48)),
        throwsA(isA<PlatformException>()),
      );
      expect(path, isNotNull);
      expect(await File(path!).exists(), isFalse);
    },
  );
}
