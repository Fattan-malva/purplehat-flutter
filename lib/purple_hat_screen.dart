import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:window_manager/window_manager.dart';

import 'services/volume_service.dart';

/// window_manager hanya untuk desktop; di Android/iOS tidak tersedia.
bool get _isDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

class PurpleHatScreen extends StatefulWidget {
  const PurpleHatScreen({super.key});

  @override
  State<PurpleHatScreen> createState() => _PurpleHatScreenState();
}

class _PurpleHatScreenState extends State<PurpleHatScreen>
    with WindowListener {
  late final WebViewController _controller;
  bool _closing = false;

  @override
  void initState() {
    super.initState();

    // Tangkap tombol close (Alt+F4 / WM_CLOSE) supaya sempat membersihkan
    // room dulu, sama seperti Form1_FormClosing di versi WinForms.
    // Hanya berlaku di desktop (window_manager tidak ada di Android/iOS).
    if (_isDesktop) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }

    _controller = WebViewController();

    // Android: izinkan media (YouTube/audio) autoplay tanpa gesture user.
    // Di Windows autoplay diatur lewat argumen WebView2
    // (--autoplay-policy=no-user-gesture-required) di runner.
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }

    _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    _controller.setBackgroundColor(Colors.black);

    // JS Channel untuk komunikasi volume
    _controller.addJavaScriptChannel(
      'purpleHatBridge',
      onMessageReceived: (JavaScriptMessage message) {
        _handleWebMessage(message.message);
      },
    );

    _controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (url) {
          _injectJavaScriptBridge();
        },
        onWebResourceError: (error) {
          // Android melaporkan error untuk SEMUA resource (CDN, font, ikon,
          // analytics), bukan cuma halaman utama. Kalau semuanya ditampilkan,
          // muncul "network error" palsu padahal halaman sudah termuat normal.
          // Jadi hanya tampilkan kalau frame utama yang benar-benar gagal.
          if (error.isForMainFrame == false) return;
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('WebView gagal dijalankan:\n${error.description}'),
              backgroundColor: Colors.red,
            ),
          );
        },
      ),
    );

    _controller.loadRequest(
      Uri.parse('https://purplehat.mallvaa.xyz/screen/index.html'),
    );
  }

  void _handleWebMessage(String message) {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      if (data['type'] != 'volume') return;

      final double volume = (data['value'] as num).toDouble();
      VolumeService.setVolumeFromPercent(volume);
    } catch (e) {
      print('WebMessage error: $e');
    }
  }

  Future<void> _injectJavaScriptBridge() async {
    // screen.js milik web memanggil volume lewat API WebView2:
    //   window.chrome.webview.postMessage(JSON.stringify({type:'volume', value:N}))
    //
    // webview_win_floating hanya meneruskan pesan yang berbentuk OBJECT:
    //   { "JkChannelName": "<nama channel>", "msg": <payload> }
    // Native memakai get_WebMessageAsJson() lalu Dart memanggil
    // json.decode() -> Map -> notifyMessageReceived_().
    //
    // PENTING: postMessage harus dikirim sebagai OBJECT, bukan string.
    // Kalau dikirim sebagai string, json.decode() menghasilkan String dan
    // jobj["JkChannelName"] gagal -> pesan hilang tanpa error.
    const bridgeScript = r'''
    (function() {
      try {
        var webview = window.chrome && window.chrome.webview;
        if (!webview || typeof webview.postMessage !== 'function') {
          return;
        }

        if (window.__purpleHatFlutterBridgeInstalled) {
          return;
        }
        window.__purpleHatFlutterBridgeInstalled = true;

        // Simpan fungsi asli WebView2 SEBELUM diganti (dipakai JkChannel
        // internal plugin). Tanpa ini akan terjadi rekursi tak berujung.
        var nativePostMessage = webview.postMessage.bind(webview);

        // Kirim payload JSON ke Dart lewat channel 'purpleHatBridge'.
        // Wajib OBJECT, otomatis diubah native menjadi {JkChannelName, msg}.
        function postToBridge(payload) {
          try {
            nativePostMessage({
              JkChannelName: 'purpleHatBridge',
              msg: JSON.stringify(payload)
            });
          } catch (e) {}
        }

        function sendVolume(value) {
          var v = Number(value);
          if (!isFinite(v)) return;
          v = Math.max(0, Math.min(100, v));
          postToBridge({ type: 'volume', value: v });
        }

        function extractVolume(message) {
          try {
            var parsed = (typeof message === 'string')
              ? JSON.parse(message)
              : message;
            if (parsed && parsed.type === 'volume') {
              return Number(parsed.value);
            }
          } catch (e) {}
          return null;
        }

        function wrappedPostMessage(message) {
          var volume = extractVolume(message);
          if (volume !== null) {
            sendVolume(volume);
            return;
          }
          return nativePostMessage(message);
        }

        try {
          webview.postMessage = wrappedPostMessage;
        } catch (e) {
          try {
            Object.defineProperty(webview, 'postMessage', {
              value: wrappedPostMessage,
              configurable: true,
              writable: true
            });
          } catch (e2) {}
        }

        // Cadangan: screen.js memakai helper global postToHost().
        try {
          window.postToHost = function(m) {
            var volume = extractVolume(m);
            if (volume !== null) {
              sendVolume(volume);
              return;
            }
            try {
              nativePostMessage(typeof m === 'string' ? m : JSON.stringify(m));
            } catch (e) {}
          };
        } catch (e) {}

        // Sinkronkan volume awal (var volume di screen.js -> window.volume).
        if (typeof window.volume === 'number') {
          sendVolume(window.volume);
        }
      } catch (e) {}
    })();
    ''';

    try {
      await _controller.runJavaScript(bridgeScript);
    } catch (e) {
      print('Bridge inject error: $e');
    }

    // Android: matikan efek render yang paling berat di GPU supaya UI tidak
    // patah-patah. Hanya menyentuh efek, tata letak tidak berubah.
    if (!_isDesktop) {
      await _applyAndroidPerformanceTweaks();
    }
  }

  /// Mengurangi beban render di Android WebView.
  ///
  /// `backdrop-filter` (blur) yang menutupi layar di atas video fullscreen
  /// sangat mahal di Android sehingga frame drop. Efek ini dimatikan, dan
  /// animasi background dihentikan; tampilan tetap sama, hanya lebih ringan.
  Future<void> _applyAndroidPerformanceTweaks() async {
    const perfCss = r'''
    (function () {
      try {
        if (document.getElementById('__ph_perf_css')) return;
        var style = document.createElement('style');
        style.id = '__ph_perf_css';
        style.textContent =
          'body{animation:none !important;}' +
          '*{backdrop-filter:none !important;-webkit-backdrop-filter:none !important;}';
        (document.head || document.documentElement).appendChild(style);
      } catch (e) {}
    })();
    ''';

    try {
      await _controller.runJavaScript(perfCss);
    } catch (e) {
      print('Android perf tweak error: $e');
    }
  }

  Future<void> _onClose() async {
    if (_closing) return;
    _closing = true;

    // Bersih-bersih setara Form1_FormClosing di WinForms:
    // ambil kode room dari sessionStorage, hapus, lalu DELETE room ke backend.
    // Memakai XMLHttpRequest sinkron supaya request benar-benar terkirim
    // sebelum WebView/window dibuang.
    try {
      const script = r'''
        (function(){
          try {
            var c = sessionStorage.getItem('ph_code');
            sessionStorage.removeItem('ph_code');
            if (!c) return;
            var x = new XMLHttpRequest();
            x.open('DELETE', '/api/room/' + c, false);
            x.send();
          } catch(e) {}
        })();
      ''';
      await _controller.runJavaScript(script);
    } catch (e) {
      print('FormClosing cleanup: $e');
    }

    // Desktop: benar-benar tutup window (walaupun preventClose aktif).
    // Mobile: keluar dari aplikasi.
    if (_isDesktop) {
      await windowManager.destroy();
    } else {
      await SystemNavigator.pop();
    }
  }

  // Dipanggil window_manager saat tombol close / Alt+F4 ditekan
  // (karena setPreventClose(true)).
  @override
  void onWindowClose() {
    _onClose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      autofocus: true,
      focusNode: FocusNode(),
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _onClose();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          cursor: SystemMouseCursors.none,
          child: WebViewWidget(controller: _controller),
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    _onClose();
    super.dispose();
  }
}
