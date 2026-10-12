import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Pencari handle jendela (HWND) di Windows untuk keperluan embed mpv.
///
/// mpv dijalankan dengan `--wid=<HWND>` supaya video Karaoke dirender DI DALAM
/// jendela aplikasi Flutter (embedded), bukan sebagai jendela terpisah.
/// Implementasi memakai langsung `user32.dll` lewat `dart:ffi` (tanpa plugin).
class NativeWindow {
  NativeWindow._();

  static DynamicLibrary? _user32;

  static DynamicLibrary get _lib {
    _user32 ??= DynamicLibrary.open('user32.dll');
    return _user32!;
  }

  static int _findWindow(String className) {
    final find = _lib.lookupFunction<_FindWindowWNative, _FindWindowWDart>(
        'FindWindowW');
    final Pointer<Utf16> cls = className.toNativeUtf16();
    try {
      return find(cls, nullptr);
    } finally {
      malloc.free(cls);
    }
  }

  static int _getActiveWindow() {
    final getActive = _lib.lookupFunction<_GetActiveWindowNative,
        _GetActiveWindowDart>('GetActiveWindow');
    return getActive();
  }

  /// HWND jendela utama Flutter, atau `null` bila tidak ditemukan / bukan
  /// Windows. Jendela Flutter memakai class `FLUTTER_RUNNER_WIN32_WINDOW`.
  ///
  /// Ada retry singkat karena jendela mungkin belum siap saat dipanggil.
  static Future<int?> flutterWindow({
    int retries = 20,
    Duration interval = const Duration(milliseconds: 100),
  }) async {
    if (!Platform.isWindows) return null;
    for (var i = 0; i < retries; i++) {
      try {
        final hwnd = _findWindow('FLUTTER_RUNNER_WIN32_WINDOW');
        if (hwnd != 0) return hwnd;
        final active = _getActiveWindow();
        if (active != 0) return active;
      } catch (_) {
        // user32 belum siap / kelas belum ada -> coba lagi.
      }
      await Future<void>.delayed(interval);
    }
    return null;
  }
}

typedef _FindWindowWNative = IntPtr Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _FindWindowWDart = int Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _GetActiveWindowNative = IntPtr Function();
typedef _GetActiveWindowDart = int Function();
