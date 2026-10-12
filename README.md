# PurpleHat Screen Player

Pembungkus (wrapper) dari aplikasi player VB.NET PurpleHat ke Flutter.
Saat dijalankan, aplikasi langsung membuka webview — tidak ada splash screen,
dialog, atau tombol apa pun.

## Isi

| File | Fungsi |
| --- | --- |
| `lib/main.dart` | Entry point, atur jendela desktop (fullscreen, tanpa title bar) |
| `lib/config.dart` | Konfigurasi: URL layar, nama pipe mpv, argumen mpv |
| `lib/purple_hat_screen.dart` | WebView + deteksi MAC + menjalankan mpv |
| `lib/services/device_identity.dart` | Deteksi identitas device (MAC) untuk pairing room |
| `lib/services/mpv_service.dart` | Jalankan/hentikan `mpv.exe` bundel (sumber Karaoke) |
| `lib/services/volume_service.dart` | Volume sistem (Core Audio) + Android |
| `lib/services/cleanup_service.dart` | `DELETE /api/room/<kode>` saat aplikasi ditutup |
| `mpv/` | `mpv.exe` + DLL (di-ignore git, lihat `docs/KARAOKE.md`) |
| `tools/download_mpv.ps1` | Unduh & ekstrak mpv ke folder `mpv/` |

## Perilaku

- **Buka langsung:** `https://purplehat.mallvaa.xyz/screen/index.html` dimuat
  begitu aplikasi start, dengan **MAC device** ditambahkan (`?mac=...`) supaya
  layar me-resolve room yang tepat. Lihat [`docs/KARAOKE.md`](docs/KARAOKE.md).
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

## Karaoke (mpv)

Aplikasi ini **menjalankan mpv** (sumber Karaoke) memakai `mpv.exe` yang ikut
ter-bundle di folder Release; backend Python cukup menyambung ke named pipe IPC
(paling ringan di sisi server, realtime untuk semua perintah).

1. Sediakan mpv (sekali):

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools/download_mpv.ps1
   ```

2. Build:

   ```bash
   flutter build windows --release
   ```

   `mpv/` otomatis tersalin ke `build\windows\x64\runner\Release\mpv\`.

3. Deploy: cukup copy folder Release ke device baru (mpv sudah termasuk).

Detail lengkap (MAC, pipe, FX, troubleshooting) ada di
[`docs/KARAOKE.md`](docs/KARAOKE.md).

## Ikon

Semua ikon dibuat dari `lib/assets/icons/new.png` untuk Android (adaptive),
iOS, macOS, Windows, Linux, dan Web:

```bash
dart run flutter_launcher_icons
```

## Menjalankan

```bash
flutter pub get

# Sediakan mpv (sekali) agar sumber Karaoke berfungsi:
powershell -ExecutionPolicy Bypass -File tools/download_mpv.ps1

flutter run -d windows      # atau -d android / -d chrome
flutter build windows --release
```

## Catatan

- Windows memakai **WebView2** lewat `webview_win_floating` + `webview_flutter`.
- Linux belum punya webview stabil di paket ini, jadi tampilannya berupa pesan
  sederhana.