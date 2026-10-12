import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config.dart';
import 'native_window.dart';

/// Menjalankan mpv (sumber Karaoke) yang IKUT ter-bundle di folder aplikasi.
///
/// Desain (lihat `docs/KARAOKE.md`):
/// - Flutter yang menjalankan `mpv.exe` -> backend Python di sisi server jadi
///   ringan (hanya menyambung ke named pipe, tidak mengelola proses mpv).
/// - Semua perintah pemutaran tetap lewat JSON IPC dan responsif/realtime.
///
/// mpv dibiarkan hidup dalam mode `--idle` (tanpa jendela sampai ada lagu),
/// jadi backend bisa mengirim perintah kapan saja.
class MpvService {
  MpvService._();

  static Process? _proc;
  static String? _exePath;

  /// Lokasi `mpv.exe`: `<dir exe>/mpv/mpv.exe`, fallback `<dir exe>/mpv.exe`.
  static String? resolveExe() {
    if (!Platform.isWindows) return null;
    if (_exePath != null && File(_exePath!).existsSync()) return _exePath;

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final candidates = <String>[
      '$exeDir$sep${PHConfig.mpvSubDir}$sep${PHConfig.mpvExe}',
      '$exeDir$sep${PHConfig.mpvExe}',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) {
        _exePath = c;
        return c;
      }
    }
    return null;
  }

  /// Jalankan mpv (sekali). Bila mpv tidak ada, lewati dengan log — layar web
  /// tetap jalan dan backend akan memakai fallback-nya (spawn mpv sendiri).
  static Future<void> start() async {
    if (!Platform.isWindows) return;

    final exe = resolveExe();
    if (exe == null) {
      debugPrint(
        'MpvService: mpv.exe tidak ditemukan di folder aplikasi. '
        'Jalankan tools/download_mpv.ps1 lalu build ulang.',
      );
      return;
    }

    if (PHConfig.killMpvOnStart) {
      await _taskkill();
    }

    final args = <String>[
      '--input-ipc-server=${PHConfig.mpvPipe}',
      ...PHConfig.mpvArgs,
    ];

    // Embed video ke DALAM jendela Flutter (--wid=<HWND>). Bila HWND tidak
    // terdeteksi, jatuh ke mode jendela mpv terpisah (fullscreen + ontop).
    int? hwnd;
    if (PHConfig.embedInFlutter) {
      hwnd = await NativeWindow.flutterWindow();
    }
    if (hwnd != null) {
      args.add('--wid=$hwnd');
    } else {
      args.addAll(PHConfig.mpvArgsSeparateWindow);
    }

    try {
      // `detached` -> tidak ada pipe stdout/stderr yang menggantung; mpv hidup
      // mandiri dan bisa dikontrol lewat named pipe IPC.
      _proc = await Process.start(
        exe,
        args,
        workingDirectory: File(exe).parent.path,
        mode: ProcessStartMode.detached,
      );
      // Tunggu sampai named pipe IPC mpv benar-benar terbuka (status standby),
      // supaya saat backend mengirim perintah play, mpv sudah siap dipanggil.
      final ready = await _waitForIpcPipe();
      debugPrint(
        'MpvService: mpv standby ($exe) pipe=${PHConfig.mpvPipe} '
        '${hwnd != null ? 'embedded wid=$hwnd' : 'window terpisah'} '
        '${ready ? '' : '[pipe belum terlihat!]'}',
      );
    } catch (e) {
      debugPrint('MpvService: gagal menjalankan mpv: $e');
    }
  }

  /// Tunggu (maks ~6 detik) sampai named pipe IPC mpv muncul di `\\.\pipe\`.
  /// Named pipe dibuat mpv saat startup, jadi keberadaannya = mpv siap standby.
  static Future<bool> _waitForIpcPipe({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (!Platform.isWindows) return false;
    final pipePath = PHConfig.mpvPipe; // mis. \\.\pipe\purplehat-mpv
    if (!pipePath.startsWith(r'\\')) return false;
    final sep = pipePath.lastIndexOf(r'\');
    final pipeDir = pipePath.substring(0, sep);      // \\.\pipe
    final pipeName = pipePath.substring(sep + 1);    // purplehat-mpv

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final dir = Directory(pipeDir);
        if (dir.existsSync()) {
          for (final e in dir.listSync()) {
            if (e.path.toLowerCase().endsWith(pipeName.toLowerCase())) {
              return true;
            }
          }
        }
      } catch (_) {
        // Pipe directory kadang belum siap -> ulangi.
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  /// Hentikan mpv saat aplikasi ditutup.
  static Future<void> stop() async {
    if (!Platform.isWindows) return;
    try {
      _proc?.kill();
    } catch (_) {}
    _proc = null;
    if (PHConfig.killMpvOnClose) {
      await _taskkill();
    }
  }

  /// Matikan semua `mpv.exe` (kiosk khusus PurpleHat).
  static Future<void> _taskkill() async {
    try {
      await Process.run(
        'taskkill',
        <String>['/F', '/IM', PHConfig.mpvExe, '/T'],
      );
    } catch (_) {
      // Tidak ada proses / taskkill tidak tersedia -> abaikan.
    }
  }
}
