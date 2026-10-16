#include "floade_raw_mouse.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>

namespace {
class FloadeRawMouse : public flutter::Plugin {
 public:
  explicit FloadeRawMouse(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar), channel_(registrar->messenger(),
            "floade/raw_mouse", &flutter::StandardMethodCodec::GetInstance()) {
    delegate_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
            -> std::optional<LRESULT> {
          if (owner_ != this) return std::nullopt;
          if ((message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) ||
              message == WM_DESTROY || message == WM_ENTERSIZEMOVE) {
            Disable();
          } else if (message == WM_INPUT && hwnd == window_) {
            RAWINPUT input{};
            UINT size = sizeof(input);
            if (GetRawInputData(reinterpret_cast<HRAWINPUT>(lparam), RID_INPUT,
                                &input, &size, sizeof(RAWINPUTHEADER)) != UINT(-1) &&
                input.header.dwType == RIM_TYPEMOUSE &&
                !(input.data.mouse.usFlags & MOUSE_MOVE_ABSOLUTE)) {
              dx_ += input.data.mouse.lLastX;
              dy_ += input.data.mouse.lLastY;
            }
            // DefWindowProc must still clean up foreground WM_INPUT.
          }
          return std::nullopt;
        });
    channel_.SetMethodCallHandler(
        [this](const flutter::MethodCall<>& call,
               std::unique_ptr<flutter::MethodResult<>> result) {
          if (call.method_name() == "enable") {
            result->Success(flutter::EncodableValue(Enable()));
          } else if (call.method_name() == "disable") {
            Disable();
            result->Success();
          } else if (call.method_name() == "read") {
            if (owner_ == this && GetForegroundWindow() != window_) Disable();
            const int64_t limit = 10000;
            const auto x = std::clamp(dx_, -limit, limit);
            const auto y = std::clamp(dy_, -limit, limit);
            dx_ -= x;
            dy_ -= y;
            result->Success(flutter::EncodableValue(flutter::EncodableList{
                flutter::EncodableValue(x), flutter::EncodableValue(y),
                flutter::EncodableValue(owner_ == this)}));
          } else {
            result->NotImplemented();
          }
        });
  }

  ~FloadeRawMouse() override {
    Disable();
    registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
  }

 private:
  bool Enable() {
    if (owner_ && owner_ != this) return false;
    const HWND view = registrar_->GetView()->GetNativeWindow();
    const HWND root = GetAncestor(view, GA_ROOT);
    if (GetForegroundWindow() != root) return false;
    RECT client{};
    if (!GetClientRect(view, &client)) return false;
    POINT center{(client.right - client.left) / 2,
                 (client.bottom - client.top) / 2};
    if (!ClientToScreen(view, &center)) return false;
    RAWINPUTDEVICE mouse{0x01, 0x02, 0, root};
    if (!RegisterRawInputDevices(&mouse, 1, sizeof(mouse))) return false;
    RECT lock{center.x, center.y, center.x + 1, center.y + 1};
    owner_ = this;
    window_ = root;
    dx_ = dy_ = 0;
    if (!SetCursorPos(center.x, center.y) || !ClipCursor(&lock)) {
      Disable();
      return false;
    }
    return true;
  }

  void Disable() {
    if (owner_ != this) return;
    RAWINPUTDEVICE mouse{0x01, 0x02, RIDEV_REMOVE, nullptr};
    RegisterRawInputDevices(&mouse, 1, sizeof(mouse));
    ClipCursor(nullptr);
    owner_ = nullptr;
    window_ = nullptr;
    dx_ = dy_ = 0;
  }

  static FloadeRawMouse* owner_;
  flutter::PluginRegistrarWindows* registrar_;
  flutter::MethodChannel<> channel_;
  int delegate_ = 0;
  HWND window_ = nullptr;
  int64_t dx_ = 0;
  int64_t dy_ = 0;
};
FloadeRawMouse* FloadeRawMouse::owner_ = nullptr;
}  // namespace

void RegisterFloadeRawMouse(FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows->AddPlugin(std::make_unique<FloadeRawMouse>(windows));
}
