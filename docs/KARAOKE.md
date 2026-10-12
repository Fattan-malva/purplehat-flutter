# PurpleHat Flutter — Integrasi Karaoke (mpv) + SQL Server

Dokumen ini menjelaskan bagaimana **player Flutter** (`purplehat-flutter`)
terintegrasi dengan fitur **Karaoke** dari backend Purplehat (`purplehat/docs/KARAOKE.md`).

Ringkasnya:

- **Identitas device (MAC)** dideteksi Flutter lalu dikirim ke halaman layar,
  supaya backend me-resolve room yang tepat (`PairingCode` stabil per device).
- Setelah pairing controller berhasil, layar meminta Flutter menjalankan
  `mpv.exe` lokal secara **standby**. Flutter menunggu IPC siap sebelum pindah
  dari QR ke player. Jendela child mpv disembunyikan sampai video karaoke dimuat.
- Pada Windows desktop, perintah `loadfile`, pause/play, seek, status, dan FX
  dikirim dari halaman screen ke Flutter lalu melalui native runner ke named
  pipe **lokal Windows**. Backend VPS tidak bisa membuka named pipe lokal itu.
  Endpoint backend untuk kontrol mpv tetap tersedia sebagai fallback non-desktop.

---

## 1. Arsitektur

```
Controller (HP) ──WebSocket──> Node/Express ──WebSocket──> Screen JS
                                                               │
                                                               │ host bridge
                                                               v
                                                    Flutter MethodChannel
                                                               │
                                                               v
                                                     Windows named pipe IPC
                                                               │
                                                               v
                                                         mpv.exe (local)

Node/Express ──HTTP──> FastAPI ──pyodbc──> SQL Server (song bank / room)
```

- Controller (HP) → Node WebSocket → screen JavaScript → Flutter bridge →
  native Windows IPC → mpv lokal.
- Saat pasangan berhasil, menu QR meminta mpv start dan **menunggu IPC siap**.
  Jendela mpv tersembunyi selama standby; loading video menampilkan child window
  mpv di atas area player.
- `/api/karaoke/player/*` tetap digunakan sebagai fallback non-desktop, bukan
  sebagai transport IPC dari VPS ke proses mpv Windows.
- **Video di-embed ke dalam jendela Flutter**: mpv dijalankan dengan
  `--wid=<HWND>` (lihat `lib/services/native_window.dart`), jadi video tampil di
  dalam jendela aplikasi (bukan jendela terpisah). Saat idle tidak ada elemen
  video, sehingga layar web terlihat. Bisa dimatikan lewat
  `PHConfig.embedInFlutter = false` (kembali ke jendela mpv terpisah fullscreen).

---

## 2. Identitas device (MAC) — sudah otomatis

`lib/services/device_identity.dart` mendeteksi identitas:

1. **Windows**: `getmac` (utama) / `wmic` (cadangan), memilih adapter **fisik**
   (Ethernet/Wi-Fi) dan melewatkan adapter virtual (Bluetooth, Hyper-V, dll).
2. **Fallback**: ID acak persisten di `%LOCALAPPDATA%\PurpleHat\device_id`
   (stabil antar restart).

Lalu `lib/purple_hat_screen.dart` mengirimkannya ke halaman layar dengan dua cara
(keduanya didukung `public/screen/menu.js`):

1. **Query string** `?mac=...` saat memuat `screen/index.html` (utama, terbaca
   sejak awal), dan
2. **Injeksi JS** `window.purplehatDeviceMac` / `window.purplehat.deviceMac`
   (cadangan).

> Tidak ada yang perlu diubah di sisi web/backend untuk MAC — mekanisme
> `deviceMac()` di `menu.js` sudah membacanya.

---

## 3. Install mpv (langkah)

mpv **tidak perlu** di-install ke Windows (tidak masuk PATH, tidak ke Program
Files). Cukup diletakkan di folder `mpv/` project ini, lalu ikut ter-bundle saat
build.

### 3.1 Cara otomatis (disarankan)

Dari folder root `purplehat-flutter`:

```powershell
powershell -ExecutionPolicy Bypass -File tools/download_mpv.ps1
```

Script akan:

1. mencari build mpv x64 terbaru di GitHub Releases
   (`zhongfly/mpv-winbuild`, cadangan `shinchiro/mpv-winbuild-cmake`),
2. mengunduhnya (`.7z`),
3. mengekstraknya memakai 7-Zip bila terpasang — kalau tidak ada, otomatis
   memakai `7zr.exe` portable,
4. menyalin `mpv.exe` + DLL pendukung ke `purplehat-flutter/mpv/`.

Opsi: `-Url <url .7z>` (lewati pencarian), `-Dest <folder>`, `-Force` (timpa).

### 3.2 Cara manual

1. Buka <https://github.com/zhongfly/mpv-winbuild/releases> (atau
   <https://github.com/shinchiro/mpv-winbuild-cmake/releases>).
2. Unduh `mpv-x86_64-<tanggal>-git-<hash>.7z` (bukan yang `-dev`, `-v3`, atau
   `debug`).
3. Ekstrak **isi** arsip (`mpv.exe`, `mpv.com`, `*.dll`, …) ke
   `purplehat-flutter/mpv/`.

> Build resmi mpv Windows umumnya sudah menyertakan **librubberband** sehingga FX
> **key shift / pitch** berfungsi. Bila tidak, pitch akan dilaporkan gagal
> (fitur lain tetap jalan). Lihat `docs/KARAOKE.md` backend untuk detail FX.

---

## 4. Build Windows — mpv otomatis ikut

`windows/CMakeLists.txt` menambahkan aturan install: isi folder `mpv/` disalin
ke `<Release>/mpv/` setiap kali build.

```powershell
flutter build windows --release
```

Hasil:

```
build\windows\x64\runner\Release\
├─ purplehat_flutter.exe
├─ flutter_windows.dll
├─ data\
└─ mpv\
   ├─ mpv.exe
   ├─ mpv.com
   └─ *.dll
```

Saat aplikasi dijalankan, `MpvService` mencari mpv di
`<dir exe>\mpv\mpv.exe` (fallback `<dir exe>\mpv.exe`) lalu menjalankannya.

---

## 5. Deploy ke device baru

1. **Flutter player**: cukup **copy folder**
   `build\windows\x64\runner\Release\` ke device baru (sudah termasuk mpv). Tidak
   perlu install mpv terpisah.
2. **Backend** (Python + Node) tetap dideploy/dijalankan terpisah di kiosk
   (lihat `purplehat/README.md`) dengan `backend/.env` yang benar.

> Pada Windows wrapper, `lib/config.dart` menentukan named pipe yang dibuka
> oleh native runner (default `\\.\pipe\purplehat-mpv`). Backend FastAPI tidak
> perlu mengakses pipe itu untuk playback Windows. Hanya bila menjalankan mode
> fallback backend, pastikan `MPV_IPC_PIPE` menunjuk ke mpv yang benar-benar
> dapat dijangkau oleh proses Python.

---

## 6. Konfigurasi

Semua knob ada di `lib/config.dart`:

| Konstanta | Arti |
| --- | --- |
| `screenUrl` | URL halaman layar yang dibungkus WebView |
| `mpvPipe` | Named pipe IPC (harus sama dengan backend) |
| `mpvSubDir` / `mpvExe` | Lokasi `mpv.exe` di folder Release |
| `embedInFlutter` | `true` = video di dalam jendela app (`--wid`); `false` = jendela mpv terpisah |
| `mpvArgs` | Argumen dasar mpv (`--force-window=no`, `--keep-open=yes`, …) |
| `mpvArgsSeparateWindow` | Argumen tambahan saat `embedInFlutter=false` (`--fs`, `--ontop`) |
| `killMpvOnStart` / `killMpvOnClose` | Bersihkan sisa proses mpv |

Di sisi backend (`backend/.env`): `MPV_LAUNCH=auto` (sambung-dulu-baru-spawn),
`external` (hanya sambung), atau `spawn` (selalu spawn sendiri).

---

## 7. Verifikasi & troubleshooting

- **Cek mpv jalan**: `tasklist | findstr mpv` (saat aplikasi terbuka).
- **Cek mode Windows desktop**: lihat log `MpvService: mpv siap` dan proses
  `mpv.exe` di Task Manager. Status playback di screen diperoleh dari mpv lokal,
  bukan dari `GET /api/karaoke/player/state`.
- **Backend fallback**: `GET /api/karaoke/player/state` memeriksa instance mpv
  yang dilihat backend; hasil ini tidak membuktikan bahwa mpv lokal Windows siap.
- **MAC salah / room beda**: cek log aplikasi (`DeviceIdentity: ...`). Bisa
  paksa nilai lewat query `?mac=` pada `screenUrl` untuk pengujian.
- **Pitch (key shift) tidak berubah**: build mpv Anda tanpa librubberband —
  pakai build resmi dari script di atas. (Diverifikasi: build zhongfly
  mendukung `rubberband=pitch-scale=…`, `equalizer`, `aecho`, dan `pan` lavfi.)
- **Video tidak muncul**: pastikan `embedInFlutter = true` dan lihat log
  `MpvService`. Jika HWND host tidak ditemukan, startup dibatalkan agar jendela
  mpv fullscreen tidak menutupi layar pairing; periksa integrasi jendela native.
- **Video embed tertutup layar web**: itu memang diharapkan saat lagu diputar.
  Setelah lagu berhenti (idle) elemen video hilang dan layar web terlihat lagi.

---

## 8. File terkait

```
purplehat-flutter/
├─ lib/
│  ├─ config.dart                     # konfigurasi (URL, pipe, argumen mpv)
│  ├─ purple_hat_screen.dart          # deteksi MAC + jalankan mpv + WebView
│  └─ services/
│     ├─ device_identity.dart         # deteksi identitas device (MAC)
│     ├─ native_window.dart           # cari HWND jendela Flutter (untuk --wid)
│     └─ mpv_service.dart             # jalankan/stop mpv bundel (embed via --wid)
├─ mpv/                               # mpv.exe + DLL (di-ignore git)
├─ tools/download_mpv.ps1             # unduh & ekstrak mpv
└─ windows/CMakeLists.txt             # salin mpv/ ke folder Release
```
