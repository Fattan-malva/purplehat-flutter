/// Konfigurasi PurpleHat player (Flutter).
///
/// Semua nilai yang biasanya perlu diubah ada di sini. Lihat juga
/// `docs/KARAOKE.md` untuk integrasi sumber Karaoke (mpv + SQL Server).
class PHConfig {
  PHConfig._();

  /// Halaman layar (screen) yang dibungkus WebView.
  ///
  /// MAC device akan ditambahkan otomatis sebagai query `?mac=...` (lihat
  /// `purple_hat_screen.dart`) supaya layar me-resolve room yang tepat.
  static const String screenUrl =
      'https://purplehat.mallvaa.xyz/screen/index.html';
  // static const String screenUrl =
  //     'https://cqz19d4x-3000.asse.devtunnels.ms/screen/index.html';

  // ---------------------------------------------------------------------------
  // mpv (sumber Karaoke)
  // ---------------------------------------------------------------------------
  // mpv DIJALANKAN oleh aplikasi ini memakai `mpv.exe` yang ikut ter-bundle di
  // folder Release (lihat windows/CMakeLists.txt). Backend Python cukup
  // menyambung ke named pipe di bawah ini (tidak menjalankan mpv sendiri).
  //
  // PENTING: nilai pipe di sini HARUS sama dengan `MPV_IPC_PIPE` di
  // `backend/.env` (default: \\.\pipe\purplehat-mpv).
  static const String mpvPipe = r'\\.\pipe\purplehat-mpv';

  /// Nama subfolder di samping `purplehat_flutter.exe` yang berisi mpv.
  static const String mpvSubDir = 'mpv';

  /// Nama file executable mpv.
  static const String mpvExe = 'mpv.exe';

  /// Embed video mpv DI DALAM jendela aplikasi Flutter (pakai `--wid=<HWND>`).
  ///
  /// `true`  -> video tampil di dalam jendela aplikasi (tanpa jendela terpisah).
  /// `false` -> perilaku lama: mpv membuka jendela sendiri fullscreen + ontop.
  ///
  /// Bila HWND jendela Flutter gagal dideteksi, otomatis jatuh ke mode jendela
  /// terpisah supaya video tetap tampil.
  static const bool embedInFlutter = true;

  /// Argumen dasar mpv.
  ///
  /// - `--force-window=immediate`: buat window child segera (embed mode).
  ///   Saat idle layar web (panggung karaoke) yang terlihat.
  /// - `--keep-open=yes`: tetap hidup setelah lagu habis agar `eof-reached`
  ///   bisa dibaca backend (memicu auto-play lagu berikutnya).
  /// - `--vo=gpu`: gunakan GPU rendering untuk performa terbaik di Windows.
  static const List<String> mpvArgs = <String>[
    '--idle=yes',
    '--keep-open=yes',
    '--no-terminal',
    '--osc=no',
    '--input-default-bindings=no',
    '--force-window=immediate',
    '--vo=gpu',
    '--title=PurpleHat Karaoke',
  ];

  /// Argumen tambahan saat video TIDAK di-embed (jendela mpv terpisah).
  static const List<String> mpvArgsSeparateWindow = <String>[
    '--fs',
    '--ontop',
  ];

  /// Matikan sisa proses mpv sebelum menjalankan yang baru (mencegah named pipe
  /// bentrok setelah crash/restart). Aman untuk kiosk khusus PurpleHat.
  static const bool killMpvOnStart = true;

  /// Matikan mpv saat aplikasi ditutup.
  static const bool killMpvOnClose = true;
}
