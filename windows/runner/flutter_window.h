#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <memory>

#include "win32_window.h"

namespace purplehat {
class WindowChannel;
}  // namespace purplehat

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Sembunyikan kursor mouse di area klien (setara Cursor.Hide() di VB).
  void SetCursorHidden(bool hidden);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // MethodChannel ke sisi Dart (setCursorHidden).
  std::unique_ptr<purplehat::WindowChannel> window_channel_;

  // MethodChannel "purplehat/native": setSystemVolume (Core Audio).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // MethodChannel "purplehat/mpv": akses IPC mpv lokal di Windows.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> mpv_channel_;

  std::atomic<bool> cursor_hidden_{false};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
