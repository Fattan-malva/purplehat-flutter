import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:window_manager/window_manager.dart';

import 'config.dart';
import 'services/device_identity.dart';
import 'services/mpv_service.dart';
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
  String _deviceId = '';

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
    // Transparan supaya video mpv (embed --wid) kelihatan di belakang WebView
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
        onPageStarted: (url) {
          // Identitas device (MAC) untuk resolusi room karaoke.
          _injectDeviceIdentity();
        },
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

    _bootstrap();
  }

  /// Jalankan mpv (sumber Karaoke) di startup agar siap standby saat pairing.
  Future<void> _bootstrap() async {
    _deviceId = await DeviceIdentity.get();

    final base = Uri.parse(PHConfig.screenUrl);
    final uri = base.replace(
      queryParameters: <String, String>{
        ...base.queryParameters,
        if (_deviceId.isNotEmpty) 'mac': _deviceId,
      },
    );

    try {
      await _controller.loadRequest(uri);
    } catch (e) {
      debugPrint('Load screen error: $e');
    }
  }

  /// Suntikkan identitas device sebagai global JS. Cadangan bila query string
  /// `?mac=` tidak terbaca (mis. setelah navigasi internal tanpa query).
  Future<void> _injectDeviceIdentity() async {
    if (_deviceId.isEmpty) return;
    final mac = jsonEncode(_deviceId); // aman untuk disisipkan ke JS
    final script = '''
      (function(){
        try {
          window.purplehatDeviceMac = $mac;
          window.purplehat = Object.assign(window.purplehat || {}, { deviceMac: $mac });
        } catch (e) {}
      })();
    ''';
    try {
      await _controller.runJavaScript(script);
    } catch (e) {
      debugPrint('Inject device identity error: $e');
    }
  }

  void _handleWebMessage(String message) {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      if (data['type'] == 'volume') {
        final double volume = (data['value'] as num).toDouble();
        VolumeService.setVolumeFromPercent(volume);
        return;
      }
      if (data['type'] == 'startMpv') {
        if (_isDesktop) _startMpvAndReply();
        return;
      }
      if (data['type'] == 'checkMpvReady') {
        if (_isDesktop) _replyMpvReady();
        return;
      }
      if (data['type'] == 'mpvCommand') {
        if (_isDesktop && data['command'] is List) {
          _runMpvCommand(data);
        }
        return;
      }
      if (data['type'] == 'mpvState') {
        if (_isDesktop) _replyMpvState();
        return;
      }
      if (data['type'] == 'mpvFx') {
        if (_isDesktop && data['fx'] is Map) {
          MpvService.applyFx(Map<String, dynamic>.from(data['fx'] as Map));
        }
        return;
      }
    } catch (e) {
      print('WebMessage error: $e');
    }
  }

  Future<void> _startMpvAndReply() async {
    var ready = false;
    try {
      await MpvService.ensureStarted();
      ready = await MpvService.isReady();
    } catch (e) {
      debugPrint('Mpv startup error: $e');
    }
    if (!mounted) return;
    try {
      await _controller.runJavaScript(
        'if (window.onMpvReady) window.onMpvReady($ready);',
      );
    } catch (_) {}
  }

  Future<void> _replyMpvReady() async {
    final ready = await MpvService.isReady();
    if (!mounted) return;
    try {
      await _controller.runJavaScript(
        'if (window.onMpvReady) window.onMpvReady($ready);',
      );
    } catch (_) {}
  }

  Future<void> _runMpvCommand(Map<String, dynamic> data) async {
    final rawCommand = data['command'];
    if (rawCommand is! List) return;
    final requestId = data['requestId'] is num
        ? (data['requestId'] as num).toInt()
        : 0;
    final result = await MpvService.command(List<dynamic>.from(rawCommand));
    final normalized = <String, dynamic>{
      'ok': result['error'] == 'success',
      'error': result['error'],
      'message': result['message'],
      'data': result['data'],
      'command': rawCommand,
    };
    if (!mounted) return;
    try {
      await _controller.runJavaScript(
        'if (window.onMpvCommandResult) '
        'window.onMpvCommandResult($requestId, ${jsonEncode(normalized)});',
      );
    } catch (e) {
      debugPrint('Mpv command callback error: $e');
    }
  }

  Future<void> _replyMpvState() async {
    final state = await MpvService.getState();
    if (!mounted) return;
    try {
      await _controller.runJavaScript(
        'if (window.onMpvState) window.onMpvState(${jsonEncode(state)});',
      );
    } catch (e) {
      debugPrint('Mpv state callback error: $e');
    }
  }

  Future<void> _injectJavaScriptBridge() async {
    // Pastikan identitas device terpasang di halaman (cadangan query string).
    await _injectDeviceIdentity();

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

        function sendStartMpv() {
          postToBridge({ type: 'startMpv' });
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
          // Semua payload screen.js masuk ke Flutter melalui wrapper object
          // yang memang diharapkan oleh webview_win_floating.
          window.postToHost = function(m) {
            var payload = m;
            try {
              if (typeof payload === 'string') payload = JSON.parse(payload);
            } catch (e) {}
            var volume = extractVolume(payload);
            if (volume !== null) {
              sendVolume(volume);
              return;
            }
            postToBridge(payload);
          };
        } catch (e) {}

        // Ekspos fungsi startMpv ke global scope untuk screen.js
        try {
          window.startMpv = sendStartMpv;
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

    if (!_isDesktop) {
      // Android: jembatani perintah volume dari web -> volume sistem Android.
      await _injectAndroidBridge();

      // Android: matikan efek render yang paling berat di GPU supaya UI tidak
      // patah-patah. Hanya menyentuh efek, tata letak tidak berubah.
      await _applyAndroidPerformanceTweaks();
    }
  }

  /// Android: menghubungkan perintah volume web ke volume sistem Android.
  ///
  /// `screen.js` memutuskan apakah dirinya berjalan di wrapper desktop lewat
  /// `isDesktop = !!(window.chrome && window.chrome.webview && ...)`.
  /// `window.chrome.webview` (WebView2) hanya ada di Windows, jadi di Android
  /// `isDesktop` bernilai false dan slider volume controller hanya mengubah
  /// volume internal iframe pemutar — volume sistem Android tidak tersentuh.
  ///
  /// Shim ini:
  ///   1. menyediakan `window.chrome.webview.postMessage` palsu yang
  ///      meneruskan pesan ke JavaScript channel `purpleHatBridge`, dan
  ///   2. memaksa `isDesktop = true` supaya `screen.js` mengirim nilai volume
  ///      ke host (Flutter), bukan ke iframe.
  ///
  /// Lalu Flutter memanggil `AudioManager.setStreamVolume(STREAM_MUSIC,
  /// FLAG_SHOW_UI)`, sehingga volume sistem berubah DAN panel volume sistem
  /// muncul — persis seperti menekan tombol volume perangkat.
  Future<void> _injectAndroidBridge() async {
    const androidBridgeScript = r'''
    (function () {
      try {
        // Hanya untuk halaman pemutar yang memuat screen.js.
        if (typeof window.setVolume !== 'function') return;
        // Cukup sekali per halaman (onPageFinished bisa terpanggil beberapa kali).
        if (window.__phAndroidBridgeInstalled) return;
        window.__phAndroidBridgeInstalled = true;

        // 1) API WebView2 palsu -> JavaScript channel 'purpleHatBridge'.
        if (!window.chrome) { window.chrome = {}; }
        if (!window.chrome.webview) { window.chrome.webview = {}; }
        window.chrome.webview.postMessage = function (msg) {
          try {
            var payload = (typeof msg === 'string') ? msg : JSON.stringify(msg);
            if (window.purpleHatBridge && window.purpleHatBridge.postMessage) {
              window.purpleHatBridge.postMessage(payload);
            }
          } catch (e) {}
        };

        // 2) Paksa mode desktop. `var isDesktop` di screen.js adalah variabel
        //    global, jadi mengubah window.isDesktop mengubah perilakunya.
        try { window.isDesktop = true; } catch (e) {}

        // 3) Sinkronkan volume yang sedang aktif ke host (dan set volume iframe
        //    ke 100 agar tidak dobel atenuasi), supaya volume sistem langsung
        //    mengikuti angka di controller tanpa harus digeser dulu.
        try {
          window.setVolume(typeof window.volume === 'number' ? window.volume : 30);
        } catch (e) {}
      } catch (e) {}
    })();
    ''';

    try {
      await _controller.runJavaScript(androidBridgeScript);
    } catch (e) {
      print('Android bridge inject error: $e');
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

    // Hentikan mpv yang dijalankan aplikasi ini (sumber Karaoke).
    if (_isDesktop) {
      await MpvService.stop();
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
