import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import 'native_window.dart';

/// Menjalankan mpv lokal pada kiosk Windows dan mengendalikannya melalui
/// named-pipe IPC yang dibuka oleh native runner. Backend tidak perlu berada
/// pada mesin yang sama dengan mpv.
class MpvService {
  MpvService._();

  static const MethodChannel _ipc = MethodChannel('purplehat/mpv');

  static Process? _proc;
  static String? _exePath;
  static int? _hwnd;
  static bool _started = false;
  static bool _paused = true;
  static Future<void>? _startingFuture;
  static Future<void> _ipcTail = Future<void>.value();
  static int _requestId = 0;

  /// Antrikan operasi penuh (bukan hanya satu baris IPC) supaya polling status
  /// tidak menyela load/unpause atau stop/play yang datang berurutan.
  static Future<T> _queueIpc<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _ipcTail = _ipcTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }).catchError((Object _) {});
    return completer.future;
  }

  static final Map<String, dynamic> _fx = <String, dynamic>{
    'pitch': 0.0,
    'echo': 0,
    'tempo': 1.0,
    'bass': 0,
    'treble': 0,
    'channel': 'stereo',
  };

  /// Lokasi mpv.exe: <folder executable>/mpv/mpv.exe, lalu fallback mpv.exe.
  static String? resolveExe() {
    if (!Platform.isWindows) return null;
    if (_exePath != null && File(_exePath!).existsSync()) return _exePath;

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final candidates = <String>[
      '$exeDir$sep${PHConfig.mpvSubDir}$sep${PHConfig.mpvExe}',
      '$exeDir$sep${PHConfig.mpvExe}',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        _exePath = candidate;
        return candidate;
      }
    }
    return null;
  }

  /// Start lazy setelah pairing. Pemanggilan paralel ikut menunggu startup sama.
  static Future<void> ensureStarted() async {
    if (!Platform.isWindows) return;

    final pending = _startingFuture;
    if (pending != null) {
      await pending;
      return;
    }

    if (_started && _proc != null && await _probeIpcPipe()) return;

    // Proses mungkin mati sementara object Process masih tersimpan. Probe
    // menganggap ERROR_SEM_TIMEOUT sebagai "siap" bila pipe hanya sedang sibuk.
    if (_started && _proc != null) {
      _started = false;
      _proc = null;
      _hwnd = null;
    }

    final startup = _startInternal();
    _startingFuture = startup;
    try {
      await startup;
    } finally {
      if (identical(_startingFuture, startup)) _startingFuture = null;
    }
  }

  static Future<void> _startInternal() async {
    final exe = resolveExe();
    if (exe == null) {
      debugPrint(
        'MpvService: mpv.exe tidak ditemukan di folder aplikasi. '
        'Jalankan tools/download_mpv.ps1 lalu build ulang.',
      );
      _started = false;
      return;
    }

    if (PHConfig.killMpvOnStart) await _taskkill();

    int? hwnd;
    if (PHConfig.embedInFlutter) {
      hwnd = await NativeWindow.flutterWindow();
      if (hwnd == null) {
        // Jangan membuka mpv sebagai fullscreen terpisah saat standby. Tunggu
        // sampai HWND host Flutter tersedia lalu retry dari menu pairing.
        debugPrint(
          'MpvService: HWND Flutter tidak ditemukan; mpv tidak dijalankan '
          'untuk mencegah jendela karaoke menutupi layar pairing.',
        );
        _started = false;
        _proc = null;
        _hwnd = null;
        return;
      }
    }

    final args = <String>[
      '--input-ipc-server=${PHConfig.mpvPipe}',
      ...PHConfig.mpvArgs,
    ];
    if (hwnd != null) {
      args.add('--wid=$hwnd');
      if (!args.any((arg) => arg.startsWith('--force-window'))) {
        args.add('--force-window=immediate');
      }
    } else {
      args.addAll(PHConfig.mpvArgsSeparateWindow);
    }

    try {
      _proc = await Process.start(
        exe,
        args,
        workingDirectory: File(exe).parent.path,
        mode: ProcessStartMode.detached,
      );

      final ready = await _waitForIpcPipe();
      if (!ready) {
        try {
          _proc?.kill();
        } catch (_) {}
        _proc = null;
        _hwnd = null;
        _started = false;
        debugPrint(
          'MpvService: proses mpv berjalan tetapi named pipe IPC tidak siap.',
        );
        return;
      }

      _hwnd = hwnd;
      _started = true;
      debugPrint(
        'MpvService: mpv siap ($exe), pipe=${PHConfig.mpvPipe}, '
        '${hwnd != null ? 'embedded wid=$hwnd' : 'jendela terpisah'}.',
      );

      // Jangan izinkan menu pindah dari QR sebelum child window kosong mpv
      // benar-benar disembunyikan. Jika tidak, jendela hitam bisa menimpa UI.
      if (hwnd != null) {
        await NativeWindow.setMpvVisible(hwnd, false);
      }
    } catch (error) {
      _started = false;
      _proc = null;
      _hwnd = null;
      debugPrint('MpvService: gagal menjalankan mpv: $error');
    }
  }

  static bool get isRunning => _started && _proc != null;

  static Future<bool> _probeIpcPipe() async {
    if (!Platform.isWindows) return false;
    try {
      return await _ipc.invokeMethod<bool>('ready') ?? false;
    } on PlatformException catch (error) {
      debugPrint('MpvService: probe IPC gagal: ${error.message}');
      return false;
    } on MissingPluginException {
      debugPrint('MpvService: native IPC channel belum tersedia.');
      return false;
    }
  }

  static Future<bool> isReady() async {
    if (!Platform.isWindows || !_started) return false;
    // Satu probe bisa bertepatan dengan perintah IPC lain. Jangan mengubah
    // lifecycle proses hanya dari satu hasil probe yang sementara gagal.
    return _probeIpcPipe();
  }

  static Future<bool> _waitForIpcPipe({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _probeIpcPipe()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  /// Kirim satu perintah JSON IPC ke mpv pada komputer Windows ini.
  static Future<Map<String, dynamic>> command(List<dynamic> command) {
    return _queueIpc<Map<String, dynamic>>(
      () => _commandInternal(command),
    );
  }

  static Future<Map<String, dynamic>> _commandInternal(
    List<dynamic> command,
  ) async {
    if (!Platform.isWindows) {
      return <String, dynamic>{'error': 'unsupported_platform'};
    }
    if (command.isEmpty) {
      return <String, dynamic>{'error': 'empty_command'};
    }
    if (!_started) await ensureStarted();
    if (!_started) {
      return <String, dynamic>{
        'error': 'mpv_not_ready',
        'message': 'mpv belum siap menerima perintah.',
      };
    }

    // Tidak perlu memanggil MethodChannel 'ready' untuk setiap kontrol.
    // Native akan membuka IPC langsung dan mengembalikan error bila mpv mati.
    final response = await _sendRaw(command);
    if (response['error'] == 'mpv_not_ready' ||
        response['error'] == 'ipc_exception') {
      _started = false;
    }
    final success = response['error'] == 'success';
    if (success && command.first == 'loadfile') {
      // loadfile mengganti sumber; unpause sekali agar play benar-benar mulai.
      final resume = await _sendRaw(<dynamic>['set_property', 'pause', false]);
      _paused = resume['error'] != 'success';
      await _setVideoVisible(true);
    } else if (success && command.first == 'stop') {
      _paused = true;
      await _setVideoVisible(false);
    } else if (success &&
        command.first == 'set_property' &&
        command.length > 2 &&
        command[1] == 'pause') {
      _paused = command[2] == true;
    }
    return response;
  }

  static Future<Map<String, dynamic>> _sendRaw(List<dynamic> command) async {
    if (!Platform.isWindows) {
      return <String, dynamic>{'error': 'unsupported_platform'};
    }

    // Native langsung mencoba membuka pipe. Jangan melakukan probe tambahan
    // untuk setiap perintah: polling status sebelumnya menggandakan round-trip.
    final requestId = ++_requestId;
    try {
      final raw = await _ipc.invokeMethod<String>(
        'command',
        <String, dynamic>{
          'json': jsonEncode(<String, dynamic>{
            'command': command,
            'request_id': requestId,
          }),
        },
      );
      if (raw == null || raw.isEmpty) {
        return <String, dynamic>{'error': 'empty_ipc_response'};
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return <String, dynamic>{'error': 'invalid_ipc_response', 'raw': raw};
      }
      if (decoded['request_id'] != requestId) {
        debugPrint(
          'MpvService: request_id tidak cocok '
          '(expected=$requestId, received=${decoded['request_id']}).',
        );
      }
      return Map<String, dynamic>.from(decoded);
    } catch (error) {
      debugPrint('MpvService: IPC command gagal: $error');
      return <String, dynamic>{'error': 'ipc_exception', 'message': '$error'};
    }
  }

  static Future<dynamic> _property(String name) async {
    final response = await _sendRaw(<dynamic>['get_property', name]);
    return response['error'] == 'success' ? response['data'] : null;
  }

  /// State lokal mpv; tidak meminta status dari backend yang mungkin berada VPS.
  static Future<Map<String, dynamic>> getState() {
    return _queueIpc<Map<String, dynamic>>(_getStateInternal);
  }

  static Future<Map<String, dynamic>> _getStateInternal() async {
    if (!Platform.isWindows || !_started) {
      return <String, dynamic>{
        'available': false,
        'playing': false,
        'paused': false,
        'position': 0,
        'duration': 0,
        'path': null,
        'ended': false,
      };
    }

    // Berurutan karena mpv Windows memakai satu instance named-pipe server.
    // Pause ditrack dari respons command; query cukup mengambil progress,
    // durasi, file aktif, dan EOF. Ini mengurangi IPC saat playback berjalan.
    final position = await _property('time-pos');
    final duration = await _property('duration');
    final path = await _property('path');
    final endedValue = await _property('eof-reached');
    final ended = endedValue == true;
    final hasFile = path is String && path.isNotEmpty;

    return <String, dynamic>{
      'available': true,
      'playing': hasFile && !_paused && !ended,
      'paused': _paused,
      'position': (position as num?)?.toDouble() ?? 0.0,
      'duration': (duration as num?)?.toDouble() ?? 0.0,
      'path': path,
      'ended': ended,
    };
  }

  static Future<Map<String, dynamic>> applyFx(
    Map<String, dynamic> fx,
  ) {
    return _queueIpc<Map<String, dynamic>>(() async {
      for (final key in <String>[
        'pitch',
        'echo',
        'tempo',
        'bass',
        'treble',
        'channel',
      ]) {
        if (fx.containsKey(key) && fx[key] != null) _fx[key] = fx[key];
      }
      return _applyFx();
    });
  }

  static Future<Map<String, dynamic>> _applyFx() async {
    final af = _buildAudioFilter(_fx);
    final afResult = await _sendRaw(<dynamic>['set_property', 'af', af]);
    await _sendRaw(<dynamic>['set_property', 'audio-pitch-correction', 'yes']);

    final tempoValue = double.tryParse('${_fx['tempo']}') ?? 1.0;
    final tempo = tempoValue.clamp(0.5, 2.0);
    await _sendRaw(<dynamic>['set_property', 'speed', tempo]);

    return <String, dynamic>{
      'ok': afResult['error'] == 'success',
      'error': afResult['error'],
      'af': af,
    };
  }

  static String _buildAudioFilter(Map<String, dynamic> fx) {
    final parts = <String>[];
    final lavfi = <String>[];
    final channel = '${fx['channel'] ?? 'stereo'}'.toLowerCase();
    const musicChannel = 'left';

    switch (channel) {
      case 'left':
        lavfi.add('pan=stereo|c0=c0|c1=c0');
        break;
      case 'right':
        lavfi.add('pan=stereo|c0=c1|c1=c1');
        break;
      case 'mono':
        lavfi.add('pan=mono|c0=0.5*c0+0.5*c1');
        break;
      case 'music':
      case 'instrumental':
        lavfi.add(musicChannel == 'right'
            ? 'pan=stereo|c0=c1|c1=c1'
            : 'pan=stereo|c0=c0|c1=c0');
        break;
      case 'vocal':
      case 'guide':
        lavfi.add(musicChannel == 'right'
            ? 'pan=stereo|c0=c0|c1=c0'
            : 'pan=stereo|c0=c1|c1=c1');
        break;
      case 'vocal-off':
      case 'vocaloff':
      case 'cancel':
        lavfi.add('pan=stereo|c0=0.5*c0-0.5*c1|c1=0.5*c1-0.5*c0');
        break;
    }

    final echo = (double.tryParse('${fx['echo'] ?? 0}') ?? 0).round();
    if (echo > 0) {
      final decay = (0.1 + (echo / 100.0) * 0.8).clamp(0.0, 0.9);
      final delay = 180 + echo * 6;
      lavfi.add('aecho=0.8:${decay.toStringAsFixed(2)}:$delay:0.35');
    }
    if (lavfi.isNotEmpty) parts.add('lavfi=[${lavfi.join(',')}]');

    final bass = double.tryParse('${fx['bass'] ?? 0}') ?? 0.0;
    final treble = double.tryParse('${fx['treble'] ?? 0}') ?? 0.0;
    if (bass.abs() >= 0.1) {
      parts.add('equalizer=f=100:width_type=o:width=2:g=${bass.toStringAsFixed(1)}');
    }
    if (treble.abs() >= 0.1) {
      parts.add('equalizer=f=8000:width_type=o:width=2:g=${treble.toStringAsFixed(1)}');
    }

    final pitch = double.tryParse('${fx['pitch'] ?? 0}') ?? 0.0;
    if (pitch.abs() >= 0.01) {
      final ratio = math.pow(2.0, pitch / 12.0).toDouble();
      parts.add('rubberband=pitch-scale=${ratio.toStringAsFixed(5)}');
    }
    return parts.join(',');
  }

  static Future<void> _setVideoVisible(bool visible) async {
    final hwnd = _hwnd;
    if (hwnd == null || !PHConfig.embedInFlutter) return;
    // setMpvVisible menangani resize dan show/hide dalam satu pencarian HWND.
    await NativeWindow.setMpvVisible(hwnd, visible);
  }

  static Future<void> stop() async {
    if (!Platform.isWindows) return;
    await _setVideoVisible(false);
    try {
      _proc?.kill();
    } catch (_) {}
    _proc = null;
    _hwnd = null;
    _started = false;
    _paused = true;
    _startingFuture = null;
    if (PHConfig.killMpvOnClose) await _taskkill();
  }

  static Future<void> _taskkill() async {
    try {
      await Process.run('taskkill', <String>['/F', '/IM', PHConfig.mpvExe, '/T']);
    } catch (_) {
      // Tidak ada proses/taskkill tidak tersedia.
    }
  }
}