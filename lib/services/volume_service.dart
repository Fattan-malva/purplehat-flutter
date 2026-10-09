import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';

/// Mengatur volume sistem.
///
/// - Windows : lewat MethodChannel "purplehat/native" memakai Core Audio
///   (IAudioEndpointVolume), persis seperti `SetSystemVolume` versi WinForms.
/// - Android/iOS : lewat plugin `flutter_volume_controller`.
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
        print('Volume set to: $percent%');
      } on MissingPluginException {
        print('SetSystemVolume: channel purplehat/native tidak tersedia.');
      } catch (e) {
        print('SetSystemVolume error: $e');
      }
      return;
    }

    // Android / iOS / macOS / Linux.
    try {
      await FlutterVolumeController.setVolume(value);
      print('Volume set to: $value');
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
