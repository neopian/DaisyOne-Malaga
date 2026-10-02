import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

Future<XFile> createExportFile(String name, Uint8List bytes) async =>
    XFile.fromData(bytes, name: name, mimeType: 'application/json');
Future<void> removeExportFile(XFile file, String name) async {}

Future<void> cleanupExportFiles() async {}
