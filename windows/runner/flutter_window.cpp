#include "flutter_window.h"

#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "flutter/generated_plugin_registrant.h"
#include "window_channel.h"

// IPC mpv berada lokal di kiosk Windows. Backend Python boleh berjalan di VPS.
namespace {
constexpr wchar_t kMpvPipePath[] = L"\\\\.\\pipe\\purplehat-mpv";

std::mutex g_mpv_ipc_mutex;

std::optional<long long> ExtractRequestId(const std::string& json) {
  const size_t key = json.find("\"request_id\"");
  if (key == std::string::npos) return std::nullopt;
  const size_t colon = json.find(':', key);
  if (colon == std::string::npos) return std::nullopt;
  const char* begin = json.c_str() + colon + 1;
  while (*begin && std::isspace(static_cast<unsigned char>(*begin))) ++begin;
  char* end = nullptr;
  const long long value = std::strtoll(begin, &end, 10);
  if (end == begin) return std::nullopt;
  return value;
}

HANDLE ConnectMpvPipe(DWORD timeout_ms) {
  const ULONGLONG started = GetTickCount64();
  do {
    HANDLE pipe = CreateFileW(
        kMpvPipePath, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, 0, nullptr);
    if (pipe != INVALID_HANDLE_VALUE) return pipe;

    const DWORD error = GetLastError();
    if (timeout_ms == 0) break;
    if (error == ERROR_PIPE_BUSY) {
      const ULONGLONG elapsed = GetTickCount64() - started;
      if (elapsed >= timeout_ms) break;
      const DWORD wait_ms = static_cast<DWORD>(
          std::min<ULONGLONG>(50, timeout_ms - elapsed));
      WaitNamedPipeW(kMpvPipePath, wait_ms);
    } else {
      Sleep(25);
    }
  } while (GetTickCount64() - started < timeout_ms);
  return INVALID_HANDLE_VALUE;
}

bool IsMpvPipeReady() {
  // ERROR_SEM_TIMEOUT berarti named pipe ada tetapi instance sedang dipakai.
  // Itu tetap berarti mpv tersedia; ERROR_FILE_NOT_FOUND berarti belum start.
  if (WaitNamedPipeW(kMpvPipePath, 0) != FALSE) return true;
  return GetLastError() == ERROR_SEM_TIMEOUT;
}

std::string SendMpvIpc(const std::string& payload) {
  // mpv Windows IPC biasanya hanya menerima satu klien pipe pada satu waktu.
  // Serialisasikan seluruh request dan jangan pernah mengembalikan event lama
  // sebagai jawaban command yang sedang diminta.
  std::lock_guard<std::mutex> lock(g_mpv_ipc_mutex);
  const auto expected_id = ExtractRequestId(payload);
  if (!expected_id.has_value()) return {};

  HANDLE pipe = ConnectMpvPipe(1500);
  if (pipe == INVALID_HANDLE_VALUE) return {};

  const std::string line = payload + "\n";
  DWORD written = 0;
  if (!WriteFile(pipe, line.data(), static_cast<DWORD>(line.size()),
                 &written, nullptr) ||
      written != static_cast<DWORD>(line.size())) {
    CloseHandle(pipe);
    return {};
  }

  std::string pending;
  pending.reserve(2048);
  const ULONGLONG deadline = GetTickCount64() + 1800;
  while (GetTickCount64() < deadline && pending.size() < 65536) {
    DWORD available = 0;
    if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) break;
    if (available == 0) {
      Sleep(3);
      continue;
    }

    char buffer[4096];
    DWORD bytes_read = 0;
    const DWORD request_size = std::min<DWORD>(
        available, static_cast<DWORD>(sizeof(buffer)));
    if (!ReadFile(pipe, buffer, request_size, &bytes_read, nullptr) ||
        bytes_read == 0) {
      break;
    }
    pending.append(buffer, bytes_read);

    size_t newline = std::string::npos;
    while ((newline = pending.find('\n')) != std::string::npos) {
      std::string candidate = pending.substr(0, newline);
      pending.erase(0, newline + 1);
      while (!candidate.empty() &&
             std::isspace(static_cast<unsigned char>(candidate.back()))) {
        candidate.pop_back();
      }
      size_t first = 0;
      while (first < candidate.size() &&
             std::isspace(static_cast<unsigned char>(candidate[first]))) {
        ++first;
      }
      if (first > 0) candidate.erase(0, first);
      if (candidate.empty()) continue;

      const auto reply_id = ExtractRequestId(candidate);
      if (reply_id.has_value() && reply_id.value() == expected_id.value()) {
        CloseHandle(pipe);
        return candidate;
      }
      // Abaikan event mpv dan balasan untuk request lain.
    }
  }

  CloseHandle(pipe);
  return {};
}
}  // namespace

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

  // MethodChannel dedicated untuk mem-probe dan mengirim JSON IPC ke mpv lokal.
  mpv_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "purplehat/mpv",
      &flutter::StandardMethodCodec::GetInstance());
  mpv_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "ready") {
          result->Success(flutter::EncodableValue(IsMpvPipeReady()));
          return;
        }
        if (call.method_name() != "command") {
          result->NotImplemented();
          return;
        }

        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) {
          result->Error("ARG", "Expected map");
          return;
        }
        const auto it = args->find(flutter::EncodableValue("json"));
        if (it == args->end()) {
          result->Error("ARG", "Missing JSON IPC payload");
          return;
        }
        const auto* payload = std::get_if<std::string>(&it->second);
        if (!payload || payload->empty()) {
          result->Error("ARG", "JSON IPC payload must be a non-empty string");
          return;
        }

        // Salin payload karena arguments milik MethodCall akan dilepas
        // setelah handler selesai. Semua operasi pipe berjalan di worker agar
        // Flutter/UI thread tidak macet saat mpv belum membalas.
        const std::string payload_copy = *payload;
        auto async_result =
            std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
                std::move(result));
        std::thread([payload_copy, async_result]() {
          const std::string reply = SendMpvIpc(payload_copy);
          if (reply.empty()) {
            async_result->Error("MPV_IPC",
                                "mpv IPC timeout or pipe unavailable");
            return;
          }
          async_result->Success(flutter::EncodableValue(reply));
        }).detach();
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
  mpv_channel_ = nullptr;
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
