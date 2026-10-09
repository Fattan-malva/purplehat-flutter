#include "flutter_window.h"

#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <windows.h>

#include <algorithm>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "window_channel.h"

// Mengatur volume sistem (default render endpoint) memakai Core Audio.
// HRESULT dikembalikan agar pemanggil bisa melaporkan kegagalan ke Dart.
static HRESULT SetSystemVolumeScalar(float level) {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  bool need_uninit = SUCCEEDED(hr);

  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioEndpointVolume* volume = nullptr;

  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator), (void**)&enumerator);
  if (SUCCEEDED(hr))
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (SUCCEEDED(hr))
    hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                          (void**)&volume);
  if (SUCCEEDED(hr))
    hr = volume->SetMasterVolumeLevelScalar(level, nullptr);

  if (volume) volume->Release();
  if (device) device->Release();
  if (enumerator) enumerator->Release();
  if (need_uninit) CoUninitialize();
  return hr;
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // MethodChannel "purplehat/native": Dart memanggil setSystemVolume untuk
  // mengubah volume sistem (setara Core Audio interop di VB.NET).
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "purplehat/native",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "setSystemVolume") {
          result->NotImplemented();
          return;
        }

        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) {
          result->Error("ARG", "Expected map");
          return;
        }

        auto it = args->find(flutter::EncodableValue("value"));
        if (it == args->end()) {
          result->Error("ARG", "Missing value");
          return;
        }

        const int32_t* v = std::get_if<int32_t>(&it->second);
        if (!v) {
          result->Error("ARG", "Value must be int");
          return;
        }

        float scalar = std::clamp(*v, 0, 100) / 100.0f;

        HRESULT hr = SetSystemVolumeScalar(scalar);
        if (FAILED(hr)) {
          result->Error("HRESULT", "SetVolume failed");
          return;
        }
        result->Success();
      });

  window_channel_ = std::make_unique<purplehat::WindowChannel>(
      this, flutter_controller_->engine()->messenger());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Lepaskan channel lebih dulu agar tidak memakai messenger yang sudah mati.
  channel_ = nullptr;
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SetCursorHidden(bool hidden) {
  cursor_hidden_ = hidden;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Sembunyikan kursor selama mouse berada di area klien (player layar),
  // sama seperti Cursor.Hide() pada aplikasi VB.
  if (message == WM_SETCURSOR && cursor_hidden_ &&
      LOWORD(lparam) == HTCLIENT) {
    ::SetCursor(nullptr);
    return TRUE;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
