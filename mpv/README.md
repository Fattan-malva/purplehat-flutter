# Folder `mpv/` — Sumber Karaoke

Folder ini adalah tempat `mpv.exe` (dan DLL pendukung) yang dipakai sumber
**Karaoke**. Isinya **tidak** di-commit ke git.

## Mengisi folder ini

Jalankan script unduh (sekali saja):

```powershell
# dari folder root project purplehat-flutter
powershell -ExecutionPolicy Bypass -File tools/download_mpv.ps1
```

Atau unduh manual build mpv Windows x64 dari
<https://github.com/zhongfly/mpv-winbuild/releases> (file `mpv-x86_64-*.7z`),
lalu ekstrak **isi** arsipnya (mpv.exe, mpv.com, *.dll) ke folder ini.

Setelah terisi, `flutter build windows --release` akan otomatis menyalin folder
ini ke `<Release>/mpv/` (lihat `windows/CMakeLists.txt`). Aplikasi lalu
menjalankannya dari sana.

> Build resmi mpv Windows umumnya sudah menyertakan `librubberband` sehingga fitur
> **key shift / pitch** (FX karaoke) berfungsi. Bila tidak, pitch akan dilaporkan
> gagal oleh backend (fitur lain tetap jalan).
