import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Pencari handle jendela (HWND) di Windows untuk keperluan embed mpv.
///
/// mpv dijalankan dengan `--wid=<HWND>` supaya video Karaoke dirender DI DALAM
/// jendela aplikasi Flutter (embedded), bukan sebagai jendela terpisah.
/// Implementasi memakai langsung `user32.dll` lewat `dart:ffi` (tanpa plugin).
class NativeWindow {
  // -----------------------------------------------------------------------
  // Additional native helpers for mpv child window management
  // -----------------------------------------------------------------------

  // Find a child window of `parent` with the given class name using FindWindowExW.
  static int? _findWindowEx(int parent, String className) {
    final find = _lib.lookupFunction<_FindWindowExWNative, _FindWindowExWDart>('FindWindowExW');
    final Pointer<Utf16> cls = className.toNativeUtf16();
    try {
      final child = find(parent, 0, cls, nullptr);
      return child != 0 ? child : null;
    } finally {
      malloc.free(cls);
    }
  }

  // SetWindowPos wrapper to bring a window to the top of Z-order.
  static void _setWindowPosTop(int hwnd) {
    const int SWP_NOMOVE = 0x0002;
    const int SWP_NOSIZE = 0x0001;
    const int SWP_SHOWWINDOW = 0x0040;
    final setPos = _lib.lookupFunction<_SetWindowPosNative, _SetWindowPosDart>('SetWindowPos');
    // HWND_TOP is defined as 0.
    setPos(hwnd, 0, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  }

  /// Search for the mpv child window (class "mpv") under the given parent HWND.
  /// Returns the child HWND if found, else null.
  static Future<int?> findMpvChild(int parent) async {
    // Try a few times because the child may appear after a short delay.
    for (int i = 0; i < 10; i++) {
      final child = _findWindowEx(parent, 'mpv');
      if (child != null) {
        return child;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return null;
  }

  /// Bring the mpv child window to the front (top of Z-order) under the Flutter
  /// window. Retries a few times until the child appears.
  static Future<void> bringMpvToFront(int parent) async {
    final child = await findMpvChild(parent);
    if (child != null) {
      // Do not force to top - keep behind webview content
      // _setWindowPosTop(child);
    }
  }

  /// Tampilkan/sembunyikan child window mpv. Saat standby jendela mpv harus
  /// tersembunyi agar layar pairing/WebView tetap terlihat.
  static Future<void> setMpvVisible(int parent, bool visible) async {
    final child = await findMpvChild(parent);
    if (child == null) return;
    if (visible) {
      await resizeMpvChild(parent);
      _setWindowPosTop(child);
      _showWindow(child, true);
    } else {
      _showWindow(child, false);
    }
  }

  static void _showWindow(int hwnd, bool visible) {
    final show = _lib.lookupFunction<_ShowWindowNative, _ShowWindowDart>(
      'ShowWindow',
    );
    show(hwnd, visible ? 5 : 0); // SW_SHOW / SW_HIDE
  }

  /// Resize the mpv child window to match the parent (Flutter) window client area.
  static Future<void> resizeMpvChild(int parent) async {
    final child = await findMpvChild(parent);
    if (child == null) return;
    final getClientRect = _lib.lookupFunction<_GetClientRectNative, _GetClientRectDart>('GetClientRect');
    final setWindowPos = _lib.lookupFunction<_SetWindowPosNative, _SetWindowPosDart>('SetWindowPos');
    final rect = calloc<RECT>();
    try {
      getClientRect(parent, rect);
      final width = rect.ref.right - rect.ref.left;
      final height = rect.ref.bottom - rect.ref.top;
      const int SWP_NOZORDER = 0x0004;
      setWindowPos(child, 0, 0, 0, width, height, SWP_NOZORDER);
    } finally {
      calloc.free(rect);
    }
  }

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

typedef _FindWindowExWNative = IntPtr Function(IntPtr parent, IntPtr childAfter, Pointer<Utf16> className, Pointer<Utf16> windowName);
typedef _FindWindowExWDart = int Function(int parent, int childAfter, Pointer<Utf16> className, Pointer<Utf16> windowName);

typedef _ShowWindowNative = Int32 Function(IntPtr hWnd, Int32 nCmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int nCmdShow);

typedef _SetWindowPosNative = Int32 Function(IntPtr hWnd, IntPtr hWndInsertAfter, Int32 X, Int32 Y, Int32 cx, Int32 cy, Uint32 uFlags);
typedef _SetWindowPosDart = int Function(int hWnd, int hWndInsertAfter, int X, int Y, int cx, int cy, int uFlags);

base class RECT extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

typedef _GetClientRectNative = Int32 Function(IntPtr hWnd, Pointer<RECT> lpRect);
typedef _GetClientRectDart = int Function(int hWnd, Pointer<RECT> lpRect);

