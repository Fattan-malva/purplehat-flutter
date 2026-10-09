import 'package:http/http.dart' as http;

class CleanupService {
  /// Hapus room dari backend saat aplikasi ditutup.
  /// Mirror dari Form1_FormClosing di VB.NET.
  static Future<void> deleteRoom(String code) async {
    if (code.isEmpty) return;
    try {
      final uri = Uri.parse('/api/room/$code');
      await http.delete(uri).timeout(const Duration(seconds: 3));
    } catch (e) {
      // ignore: avoid_print
      print('Cleanup error: $e');
    }
  }
}