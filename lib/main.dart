import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'features/account/export_file.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Remove only this feature's abandoned private export files. Failure must not
  // delay or block sign-in; export creation also retries scoped cleanup.
  unawaited(
    cleanupAccountExportFiles()
        .timeout(const Duration(seconds: 3))
        .catchError((Object _) {}),
  );
  runApp(const ProviderScope(child: ConciergeApp()));
}
