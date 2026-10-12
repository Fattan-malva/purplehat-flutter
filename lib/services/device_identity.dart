import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Identitas device untuk pairing room.
///
/// Server (FastAPI) mencocokkan identitas ini ke tabel `MstRoom.MacAddress`
/// agar `PairingCode` STABIL per device (lihat `docs/KARAOKE.md`). Browser
/// tidak bisa membaca MAC, jadi nilainya dideteksi di sini lalu dikirim ke
/// halaman layar oleh `purple_hat_screen.dart`.
///
/// Urutan deteksi:
///   1. Windows : `getmac`/`wmic` (adapter fisik yang aktif).
///   2. Fallback: ID acak yang DISIMPAN (stabil antar restart) di
///      `%LOCALAPPDATA%\PurpleHat\device_id`.
class DeviceIdentity {
  DeviceIdentity._();

  static String? _cached;

  /// Kembalikan identitas device (di-cache setelah pemanggilan pertama).
  static Future<String> get() async {
    if (_cached != null && _cached!.isNotEmpty) return _cached!;

    String id = '';
    if (Platform.isWindows) {
      id = (await _windowsMac()) ?? '';
    }
    if (id.isEmpty) {
      id = await _persistedFallback();
    }
    _cached = id;
    debugPrint('DeviceIdentity: $id');
    return id;
  }

  // ---------------------------------------------------------------------------
  // Windows: MAC adapter fisik
  // ---------------------------------------------------------------------------
  static final RegExp _macRe =
      RegExp(r'([0-9A-Fa-f]{2}(?:[-:][0-9A-Fa-f]{2}){5})');

  // Nama adapter yang DILEWATI (virtual/bukan fisik).
  static const List<String> _virtualHints = <String>[
    'bluetooth',
    'virtual',
    'vmware',
    'hyper-v',
    'vethernet',
    'loopback',
    'vpn',
    'wsl',
    'teredo',
    'tunnel',
    'tap-',
    'docker',
    'npcap',
    'wi-fi direct',
    'pseudo',
  ];

  static Future<String?> _windowsMac() async {
    return await _fromGetmac() ?? await _fromWmic();
  }

  static Future<String?> _fromGetmac() async {
    try {
      final r = await Process.run('getmac', <String>['/v', '/fo', 'csv', '/nh']);
      if (r.exitCode != 0) return null;
      return _pickMac(r.stdout.toString());
    } catch (e) {
      debugPrint('DeviceIdentity: getmac gagal: $e');
      return null;
    }
  }

  static Future<String?> _fromWmic() async {
    try {
      final r = await Process.run('wmic', <String>[
        'nic',
        'where',
        'NetEnabled=true and PhysicalAdapter=true',
        'get',
        'MACAddress,NetConnectionID',
        '/format:csv',
      ]);
      if (r.exitCode != 0) return null;
      return _pickMac(r.stdout.toString());
    } catch (e) {
      debugPrint('DeviceIdentity: wmic gagal: $e');
      return null;
    }
  }

  /// Pilih MAC dari keluaran CSV: utamakan adapter fisik (Ethernet/Wi-Fi).
  static String? _pickMac(String text) {
    String? physical;
    String? nonVirtual;
    String? any;

    for (final line in text.split(RegExp(r'\r?\n'))) {
      final m = _macRe.firstMatch(line);
      if (m == null) continue;
      final mac = m.group(1)!;
      if (_isZero(mac)) continue;

      final lower = line.toLowerCase();
      final isVirtual = _virtualHints.any(lower.contains);
      final looksPhysical = lower.contains('ethernet') ||
          lower.contains('wi-fi') ||
          lower.contains('wifi') ||
          lower.contains('wlan') ||
          lower.contains('wireless');

      any ??= mac;
      if (!isVirtual) {
        nonVirtual ??= mac;
        if (looksPhysical) physical ??= mac;
      }
    }
    return physical ?? nonVirtual ?? any;
  }

  static bool _isZero(String mac) {
    final hex = mac.replaceAll(RegExp(r'[:-]'), '');
    return hex == '0' * hex.length;
  }

  // ---------------------------------------------------------------------------
  // Fallback: ID acak persisten (stabil antar restart)
  // ---------------------------------------------------------------------------
  static Future<String> _persistedFallback() async {
    try {
      final file = File(
        '${_configDir().path}${Platform.pathSeparator}device_id',
      );
      if (await file.exists()) {
        final saved = (await file.readAsString()).trim();
        if (saved.isNotEmpty) return saved;
      }
      final id = _randomId();
      await file.writeAsString(id, flush: true);
      return id;
    } catch (e) {
      debugPrint('DeviceIdentity: simpan fallback gagal: $e');
      return _randomId();
    }
  }

  static Directory _configDir() {
    String base;
    if (Platform.isWindows) {
      base = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    } else if (Platform.isAndroid || Platform.isIOS) {
      base = Directory.systemTemp.path;
    } else {
      base = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    }
    final dir = Directory('$base${Platform.pathSeparator}PurpleHat');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// ID acak berprefiks agar TIDAK disalahartikan sebagai MAC 12-digit oleh
  /// normalisasi server (server memakai nilai apa adanya untuk id non-MAC).
  static String _randomId() {
    final rnd = Random.secure();
    final hex = List<String>.generate(
      16,
      (_) => rnd.nextInt(16).toRadixString(16),
    ).join();
    return 'PH-$hex';
  }
}
