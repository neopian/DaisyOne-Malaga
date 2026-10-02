import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:path_provider/path_provider.dart';

final _activeNames = <String>{};

Future<XFile> createExportFile(String name, Uint8List bytes) async {
  final temporary = await getTemporaryDirectory();
  final directory = await Directory(
    '${temporary.path}/account-export',
  ).create(recursive: true);
  _activeNames.add(name);
  final File file;
  try {
    file = await File(
      '${directory.path}/$name',
    ).writeAsBytes(bytes, flush: true);
  } catch (_) {
    _activeNames.remove(name);
    rethrow;
  }
  return XFile(file.path, name: name, mimeType: 'application/json');
}

Future<void> removeExportFile(XFile file, String name) async {
  _activeNames.remove(name);
  final original = File(file.path);
  if (await original.exists()) await original.delete();
  // Android's plugin copy must outlive the chooser: a selected receiver may
  // still be reading it after the share Future completes. Exact feature-owned
  // copies are cleared on the next startup/export, not by a completion timer.
}

/// Clears only abandoned exports this feature owns, including interrupted share
/// operations from a previous process. Active shares in this process survive.
Future<void> cleanupExportFiles() async {
  final temporary = await getTemporaryDirectory();
  for (final suffix in ['account-export', 'share_plus']) {
    final directory = Directory('${temporary.path}/$suffix');
    if (!await directory.exists()) continue;
    await for (final entity in directory.list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (entity is File &&
          RegExp(r'^account-export-[0-9]+\.json$').hasMatch(name) &&
          !_activeNames.contains(name)) {
        await entity.delete();
      }
    }
  }
}
