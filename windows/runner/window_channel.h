#ifndef RUNNER_WINDOW_CHANNEL_H_
#define RUNNER_WINDOW_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

class FlutterWindow;

namespace purplehat {

// MethodChannel kecil yang menghubungkan sisi Dart dengan runner Windows.
// Saat ini hanya satu perintah: setCursorHidden.
class WindowChannel {
 public:
  WindowChannel(FlutterWindow* window, flutter::BinaryMessenger* messenger);
  ~WindowChannel();

 private:
  FlutterWindow* window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace purplehat

#endif  // RUNNER_WINDOW_CHANNEL_H_