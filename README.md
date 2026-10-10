# PurpleHat Screen Player

Pembungkus (wrapper) dari aplikasi player VB.NET PurpleHat ke Flutter.
Saat dijalankan, aplikasi langsung membuka webview — tidak ada splash screen,
dialog, atau tombol apa pun.

## Isi

| File | Fungsi |
| --- | --- |
| `lib/main.dart` | Entry point, atur jendela desktop (fullscreen, tanpa title bar) |
| `lib/src/config.dart` | Semua konfigurasi: URL, nama handler, room key, langkah volume |
| `lib/src/purplehat_screen.dart` | Webview + JavaScript handler |
| `lib/src/host_bridge_js.dart` | JS yang disuntik ke halaman (jembatan WebView2 ↔ Dart) |
| `lib/src/host_channel.dart` | Volume sistem (Core Audio) + MethodChannel ke runner Windows |
| `lib/src/session_cleanup.dart` | `DELETE /api/room/<kode>` saat aplikasi ditutup |

## Perilaku

- **Buka langsung:** `https://purplehat.mallvaa.xyz/screen/index.html` dimuat
  begitu aplikasi start.
- **Volume:** halaman mengirim `{"type":"volume","value":46}` → volume OS
  diubah (Core Audio di Windows, `volume_controller` di Android/macOS/Linux).
  Nilai dibulatkan ke kelipatan 2 (jaring pengaman), dan OSD dimatikan.
  Bridge JS menerima juga `chrome.web.postMessage`, `chrome.webview.postMessage`,
  `window.postMessage`, dan `window.purplehat.volume(46)`.
- **Tutup aplikasi:** room dilepas dulu (`DELETE /api/room/<ph_code>`), baru
  jendela ditutup.
- **Desktop:** layar penuh, tanpa title bar, kursor mouse disembunyikan
  (`Cursor.Hide()` ala VB), autoplay WebView2 diizinkan lewat
  `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`.
- **Android:** immersive fullscreen + `KEEP_SCREEN_ON` + landscape.
- **Gagal load:** otomatis reload tiap 5 detik.

## Ikon

Semua ikon dibuat dari `lib/assets/icons/new.png` untuk Android (adaptive),
iOS, macOS, Windows, Linux, dan Web:

```bash
dart run flutter_launcher_icons
```

## Menjalankan

```bash
flutter pub get
flutter run -d windows      # atau -d android / -d chrome
flutter build windows --release
```

## Catatan

- Windows memakai **WebView2** lewat `flutter_inappwebview`.
- Linux belum punya webview di versi stabil `flutter_inappwebview`, jadi
  tampilannya berupa pesan sederhana.