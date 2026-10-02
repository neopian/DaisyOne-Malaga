import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:share_plus/share_plus.dart';

import 'export_file_stub.dart'
    if (dart.library.io) 'export_file_native.dart'
    as platform;

Future<void> cleanupAccountExportFiles() => platform.cleanupExportFiles();

Future<ShareResult> shareAccountExport(String json, Rect origin) async {
  await cleanupAccountExportFiles();
  final name = 'account-export-${DateTime.now().microsecondsSinceEpoch}.json';
  final file = await platform.createExportFile(
    name,
    Uint8List.fromList(utf8.encode(json)),
  );
  try {
    return await SharePlus.instance.share(
      ShareParams(
        files: [file],
        fileNameOverrides: [name],
        title: '내 계정 데이터',
        sharePositionOrigin: origin,
        downloadFallbackEnabled: true,
      ),
    );
  } finally {
    await platform.removeExportFile(file, name);
  }
}
