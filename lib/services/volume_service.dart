import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';

/// Mengatur volume sistem.
///
/// - Windows : lewat MethodChannel "purplehat/native" memakai Core Audio
///   (IAudioEndpointVolume), persis seperti `SetSystemVolume` versi WinForms.
///   CATATAN: jangan diubah, sudah fix.
/// - Android : lewat plugin `flutter_volume_controller` -> Android
///   `AudioManager.setStreamVolume()` dengan stream `STREAM_MUSIC`
///   (volume media/sistem yang diatur tombol volume). Butuh permission
///   `MODIFY_AUDIO_SETTINGS` di AndroidManifest.
/// - iOS/macOS/Linux : lewat plugin `flutter_volume_controller`.
class VolumeService {
  static const MethodChannel _channel = MethodChannel('purplehat/native');

  /// [value] dalam rentang 0.0 - 1.0 (scalar).
  static Future<void> setSystemVolume(double value) async {
    // Clamp volume ke rentang 0.0 - 1.0
    value = value.clamp(0.0, 1.0);

    if (defaultTargetPlatform == TargetPlatform.windows) {
      // Native menerima persen bulat 0 - 100.
      final int percent = (value * 100).round();

      try {
        await _channel.invokeMethod<void>('setSystemVolume', <String, dynamic>{
          'value': percent,
        });
      } on MissingPluginException {
        
      } catch (e) {
        print('SetSystemVolume error: $e');
      }
      return;
    }

    // Android: ubah volume sistem lewat AudioManager.setStreamVolume().
    // Stream `music` = AudioManager.STREAM_MUSIC, yaitu volume media/sistem
    // yang diatur tombol volume perangkat.
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await FlutterVolumeController.setVolume(
          value,
          stream: AudioStream.music,
        );
      } catch (e) {
        print('SetSystemVolume (Android) error: $e');
      }
      return;
    }

    // iOS / macOS / Linux.
    try {
      await FlutterVolumeController.setVolume(value);
    } catch (e) {
      print('SetSystemVolume error: $e');
    }
  }

  /// [volume] dalam persen 0 - 100.
  ///
  /// Dibulatkan ke kelipatan 2 sebagai jaring pengaman, sama seperti
  /// `WebView_WebMessageReceived` di versi WinForms.
  static Future<void> setVolumeFromPercent(double volume) async {
    // Clamp persentase ke rentang 0 - 100
    volume = volume.clamp(0.0, 100.0);

    // Bulatkan ke kelipatan 2 terdekat
    volume = (volume / 2.0).round() * 2.0;

    await setSystemVolume(volume / 100.0);
  }
}
