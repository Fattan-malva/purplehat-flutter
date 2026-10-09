import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'purple_hat_screen.dart';

/// window_manager hanya punya implementasi desktop. Di Android/iOS plugin ini
/// tidak ada, jadi memanggilnya sebelum runApp bikin app berhenti di logo.
bool get isDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (isDesktop) {
    await windowManager.ensureInitialized();

    // Konfigurasi window: fullscreen tanpa title bar
    const windowOptions = WindowOptions(
      titleBarStyle: TitleBarStyle.hidden, // Sembunyikan title bar
      fullScreen: true, // Langsung fullscreen
      backgroundColor: Colors.black,
      skipTaskbar: false,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      // Pastikan benar-benar fullscreen (bukan sekedar maximize)
      await windowManager.setFullScreen(true);
    });
  }

  runApp(const PurpleHatApp());
}

class PurpleHatApp extends StatelessWidget {
  const PurpleHatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PurpleHat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const PurpleHatScreen(),
    );
  }
}
