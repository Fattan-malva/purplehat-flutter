# third_party

## webview_win_floating

Salinan (vendor) dari plugin
[`jakky1/webview_win_floating`](https://github.com/jakky1/webview_win_floating)
versi **3.0.3** (MIT), dipakai lewat `dependency_overrides` di `pubspec.yaml`.

### Kenapa di-vendor

Autoplay bersuara di WebView2 butuh izin `Autoplay`
(`COREWEBVIEW2_PERMISSION_KIND_AUTOPLAY = 9`). Plugin asli punya dua masalah:

1. `WinWebViewPermissionResourceType` hanya memetakan kind `0..6`, sementara
   `webview_win_floating_method_channel.dart` menulis
   `WinWebViewPermissionResourceType.values[kind]` — untuk kind `>= 7`
   (Autoplay=9, FileReadWrite=8, dsb.) ini melempar **RangeError**, sehingga
   permintaan izin menggantung dan autoplay ditolak → embed Spotify mulai
   dalam keadaan mute.
2. Tidak ada anggota `autoplay`, jadi aplikasi tak bisa mengenali/memberi izin.

### Perubahan terhadap upstream

- `lib/webview_win_floating.dart`: enum `WinWebViewPermissionResourceType`
  dilengkapi mengikuti urutan `COREWEBVIEW2_PERMISSION_KIND` (7..13, termasuk
  `autoplay`).
- `lib/webview_win_floating_method_channel.dart`: pemetaan `kind` diberi guard
  batas indeks sehingga kind baru tidak melempar error.

Tidak ada perubahan pada kode native (Windows/Linux). Izin autoplay diberikan
oleh aplikasi di `lib/purple_hat_screen.dart` lewat `onPermissionRequest`.
