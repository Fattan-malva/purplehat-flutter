#include "window_channel.h"

#include "flutter_window.h"

namespace purplehat {

WindowChannel::WindowChannel(FlutterWindow* window,
                             flutter::BinaryMessenger* messenger)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "purplehat/host", &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setCursorHidden") {
          bool hidden = false;
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments != nullptr) {
            const auto it = arguments->find(flutter::EncodableValue("hidden"));
            if (it != arguments->end()) {
              hidden = std::get<bool>(it->second);
            }
          }
          window_->SetCursorHidden(hidden);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

WindowChannel::~WindowChannel() {}

}  // namespace purplehat