#include "floade_mini_preview.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cmath>

namespace {
class FloadeMiniPreview : public flutter::Plugin {
 public:
  explicit FloadeMiniPreview(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar), channel_(registrar->messenger(),
            "floade/mini_preview", &flutter::StandardMethodCodec::GetInstance()) {
    delegate_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
            -> std::optional<LRESULT> {
          if (!active_) return std::nullopt;
          if (message == WM_GETMINMAXINFO) {
            const auto info = reinterpret_cast<MINMAXINFO*>(lparam);
            info->ptMinTrackSize = {Scale(240), Scale(collapsed_ ? 44 : 140)};
            return 0;
          }
          if (message == WM_SIZING && !collapsed_) {
            auto rect = reinterpret_cast<RECT*>(lparam);
            const LONG proposed = wparam == WMSZ_TOP || wparam == WMSZ_BOTTOM
                ? static_cast<LONG>((rect->bottom - rect->top - Scale(44)) * ratio_) + Scale(16)
                : rect->right - rect->left;
            const LONG width = std::clamp(proposed, Scale(240), Scale(800));
            const LONG height = static_cast<LONG>((width - Scale(16)) / ratio_) + Scale(44);
            if (wparam == WMSZ_LEFT || wparam == WMSZ_TOPLEFT || wparam == WMSZ_BOTTOMLEFT) {
              rect->left = rect->right - width;
            } else {
              rect->right = rect->left + width;
            }
            if (wparam == WMSZ_TOP || wparam == WMSZ_TOPLEFT || wparam == WMSZ_TOPRIGHT) {
              rect->top = rect->bottom - height;
            } else {
              rect->bottom = rect->top + height;
            }
            return TRUE;
          }
          return std::nullopt;
        });
    channel_.SetMethodCallHandler(
        [this](const flutter::MethodCall<>& call,
               std::unique_ptr<flutter::MethodResult<>> result) {
          window_ = GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
          if (call.method_name() == "enter") {
            if (active_) { result->Success(); return; }
            placement_.length = sizeof(placement_);
            if (!GetWindowPlacement(window_, &placement_)) {
              result->Error("WINDOW_UNAVAILABLE", "Cannot read the remote window position.");
              return;
            }
            if (placement_.showCmd == SW_SHOWMINIMIZED) {
              placement_.showCmd = placement_.flags & WPF_RESTORETOMAXIMIZED
                  ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
            }
            topmost_ = (GetWindowLongPtr(window_, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
            active_ = true;
            collapsed_ = false;
            const auto args = std::get_if<flutter::EncodableMap>(call.arguments());
            RECT rect{};
            GetWindowRect(window_, &rect);
            MONITORINFO monitor{sizeof(MONITORINFO)};
            GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &monitor);
            LONG width = Scale(336);
            LONG left = monitor.rcWork.right - width - Scale(20);
            LONG top = monitor.rcWork.bottom - Scale(224) - Scale(20);
            if (args) {
              const auto ratio = args->find(flutter::EncodableValue("ratio"));
              if (ratio != args->end() && std::holds_alternative<double>(ratio->second)) {
                const auto value = std::get<double>(ratio->second);
                if (std::isfinite(value) && value > 0) ratio_ = std::clamp(value, 0.5, 4.0);
              }
              const auto bounds = args->find(flutter::EncodableValue("bounds"));
              if (bounds != args->end()) {
                const auto list = std::get_if<flutter::EncodableList>(&bounds->second);
                if (list && list->size() == 4 &&
                    std::all_of(list->begin(), list->end(), [](const auto& v) { return std::holds_alternative<int32_t>(v); })) {
                  left = std::get<int32_t>((*list)[0]);
                  top = std::get<int32_t>((*list)[1]);
                  width = std::clamp<LONG>(std::get<int32_t>((*list)[2]), Scale(240), Scale(800));
                  rect = {left, top, left + width, top + Scale(224)};
                  GetMonitorInfo(MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST), &monitor);
                }
              }
            }
            const LONG height = static_cast<LONG>((width - Scale(16)) / ratio_) + Scale(44);
            left = std::clamp(left, monitor.rcWork.left, std::max(monitor.rcWork.left, monitor.rcWork.right - width));
            top = std::clamp(top, monitor.rcWork.top, std::max(monitor.rcWork.top, monitor.rcWork.bottom - height));
            ShowWindow(window_, SW_SHOWNORMAL);
            if (!SetWindowPos(window_, HWND_TOPMOST, left, top, width, height, SWP_NOACTIVATE)) {
              active_ = false;
              SetWindowPlacement(window_, &placement_);
              result->Error("WINDOW_UNAVAILABLE", "Cannot enter the preview window.");
              return;
            }
            result->Success();
          } else if (call.method_name() == "bounds") {
            RECT rect{};
            GetWindowRect(window_, &rect);
            if (collapsed_) { rect.right = rect.left + expanded_.right - expanded_.left; rect.bottom = rect.top + expanded_.bottom - expanded_.top; }
            result->Success(flutter::EncodableValue(flutter::EncodableList{
                flutter::EncodableValue(static_cast<int32_t>(rect.left)),
                flutter::EncodableValue(static_cast<int32_t>(rect.top)),
                flutter::EncodableValue(static_cast<int32_t>(rect.right - rect.left)),
                flutter::EncodableValue(static_cast<int32_t>(rect.bottom - rect.top))}));
          } else if (call.method_name() == "collapse" && active_) {
            RECT rect{};
            GetWindowRect(window_, &rect);
            if (!collapsed_) expanded_ = rect;
            const LONG width = collapsed_ ? expanded_.right - expanded_.left : Scale(240);
            const LONG height = collapsed_ ? expanded_.bottom - expanded_.top : Scale(44);
            if (!SetWindowPos(window_, HWND_TOPMOST, 0, 0, width, height, SWP_NOMOVE | SWP_NOACTIVATE)) {
              result->Error("WINDOW_UNAVAILABLE", "Cannot resize the preview window.");
              return;
            }
            collapsed_ = !collapsed_;
            result->Success(flutter::EncodableValue(collapsed_));
          } else if (call.method_name() == "restore") {
            if (active_) {
              active_ = collapsed_ = false;
              SetWindowPos(window_, topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST,
                           0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
              if (!SetWindowPlacement(window_, &placement_)) {
                result->Error("WINDOW_UNAVAILABLE", "Cannot restore the remote window.");
                return;
              }
            }
            result->Success();
          } else {
            result->NotImplemented();
          }
        });
  }

  ~FloadeMiniPreview() override {
    registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
  }

 private:
  LONG Scale(int value) const { return MulDiv(value, GetDpiForWindow(window_), 96); }
  flutter::PluginRegistrarWindows* registrar_;
  flutter::MethodChannel<> channel_;
  HWND window_ = nullptr;
  WINDOWPLACEMENT placement_{};
  RECT expanded_{};
  bool active_ = false;
  bool collapsed_ = false;
  bool topmost_ = false;
  double ratio_ = 16.0 / 9.0;
  int delegate_ = 0;
};
}  // namespace

void RegisterFloadeMiniPreview(FlutterDesktopPluginRegistrarRef registrar) {
  auto windows = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows->AddPlugin(std::make_unique<FloadeMiniPreview>(windows));
}
