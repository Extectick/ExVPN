#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {
struct CanvasMetrics {
  RECT work;
  LONG frame_width;
  LONG frame_height;
  double width;
  double height;
  double maximum_scale;
};

CanvasMetrics Metrics(HWND window, int width, int height, UINT dpi = 0,
                      HMONITOR monitor = nullptr) {
  if (!monitor) monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  if (!dpi) dpi = FlutterDesktopGetDpiForMonitor(monitor);
  if (!dpi) dpi = 96;
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, &info)) {
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &info.rcWork, 0);
  }
  // WM_NCCALCSIZE makes the full window the Flutter client canvas.
  const LONG frame_width = 0;
  const LONG frame_height = 0;
  const double physical_width = width * dpi / 96.0;
  const double physical_height = height * dpi / 96.0;
  const double maximum_scale = std::max(
      0.1, std::min((info.rcWork.right - info.rcWork.left - frame_width) /
                        physical_width,
                    (info.rcWork.bottom - info.rcWork.top - frame_height) /
                        physical_height));
  return {info.rcWork, frame_width, frame_height, physical_width,
          physical_height, maximum_scale};
}

LONG OuterWidth(const CanvasMetrics& metrics, double scale) {
  return static_cast<LONG>(std::lround(metrics.width * scale)) +
         metrics.frame_width;
}

LONG OuterHeight(const CanvasMetrics& metrics, double scale) {
  return static_cast<LONG>(std::lround(metrics.height * scale)) +
         metrics.frame_height;
}

void KeepInWorkArea(RECT* bounds, const RECT& work) {
  const LONG width = bounds->right - bounds->left;
  const LONG height = bounds->bottom - bounds->top;
  bounds->left = std::clamp(bounds->left, work.left,
                            std::max(work.left, work.right - width));
  bounds->top = std::clamp(bounds->top, work.top,
                           std::max(work.top, work.bottom - height));
  bounds->right = bounds->left + width;
  bounds->bottom = bounds->top + height;
}

// Flutter's child covers the client, including the resize border. Let the
// parent receive border hit tests without intercepting any Flutter controls.
LRESULT CALLBACK ClientFrameProc(HWND child, UINT message, WPARAM wparam,
                                 LPARAM lparam, UINT_PTR id, DWORD_PTR) {
  if (message == WM_NCHITTEST) {
    const auto hit = SendMessageW(GetParent(child), message, wparam, lparam);
    if (hit >= HTLEFT && hit <= HTBOTTOMRIGHT) return HTTRANSPARENT;
  } else if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(child, ClientFrameProc, id);
  }
  return DefSubclassProc(child, message, wparam, lparam);
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // The Flutter header owns the caption; keep the resize frame and OS menu.
  SetWindowLongPtrW(GetHandle(), GWL_STYLE,
                   GetWindowLongPtrW(GetHandle(), GWL_STYLE) & ~WS_MAXIMIZEBOX);
  if (!ResizeForLayout()) return false;
  const MARGINS shadow{1, 1, 1, 1};
  DwmExtendFrameIntoClientArea(GetHandle(), &shadow);

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
  vpn_bridge_ = std::make_unique<VpnBridge>(
      flutter_controller_->engine()->messenger(), GetHandle());
  tray_icon_ = std::make_unique<TrayIcon>(
      flutter_controller_->engine()->messenger(), GetHandle());
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "exvpn/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "startDrag") {
      ReleaseCapture();
      // Return before entering Windows' modal move loop.
      POINT cursor{};
      GetCursorPos(&cursor);
      PostMessageW(GetHandle(), WM_NCLBUTTONDOWN, HTCAPTION,
                   MAKELPARAM(cursor.x, cursor.y));
      result->Success();
      return;
    }
    if (call.method_name() == "minimize") {
      ShowWindow(GetHandle(), SW_MINIMIZE);
      result->Success();
      return;
    }
    if (call.method_name() == "close") {
      PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
      result->Success();
      return;
    }
    if (call.method_name() == "setColors") {
      const auto* args = call.arguments()
          ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      if (!args || args->size() != 2) {
        result->Error("invalid_window_colors", "Invalid window colors.");
        return;
      }
      const auto color = args->find(flutter::EncodableValue("background"));
      const auto dark = args->find(flutter::EncodableValue("dark"));
      const auto* is_dark = dark != args->end()
          ? std::get_if<bool>(&dark->second) : nullptr;
      int64_t argb = -1;
      if (color != args->end()) {
        if (const auto* v = std::get_if<int32_t>(&color->second)) argb = *v;
        if (const auto* v = std::get_if<int64_t>(&color->second)) argb = *v;
      }
      if (!is_dark || argb < 0 || argb > 0xffffffffLL) {
        result->Error("invalid_window_colors", "Invalid window colors.");
        return;
      }
      const BOOL use_dark = *is_dark ? TRUE : FALSE;
      DwmSetWindowAttribute(GetHandle(), 20, &use_dark, sizeof(use_dark));
      const COLORREF border = RGB((argb >> 16) & 0xff, (argb >> 8) & 0xff,
                                  argb & 0xff);
      // Border color is optional on older Windows 10 versions.
      DwmSetWindowAttribute(GetHandle(), 34, &border, sizeof(border));
      result->Success();
      return;
    }
    if (call.method_name() != "setLayout") {
      result->NotImplemented();
      return;
    }
    const auto* arguments =
        call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments())
            : nullptr;
    const auto mode_entry = arguments
                                ? arguments->find(flutter::EncodableValue("mode"))
                                : flutter::EncodableMap::const_iterator{};
    const auto* mode = arguments && arguments->size() == 1 &&
                               mode_entry != arguments->end()
                           ? std::get_if<std::string>(&mode_entry->second)
                           : nullptr;
    int width = 0;
    int height = 0;
    if (mode && *mode == "minimal") {
      width = 400;
      height = 440;
    } else if (mode && *mode == "medium") {
      width = 440;
      height = 760;
    } else if (mode && *mode == "large") {
      width = 1040;
      height = 680;
    } else {
      result->Error("invalid_window_layout", "Unknown window layout.");
      return;
    }
    const int previous_width = canvas_width_;
    const int previous_height = canvas_height_;
    canvas_width_ = width;
    canvas_height_ = height;
    if (ResizeForLayout()) {
      result->Success();
    } else {
      canvas_width_ = previous_width;
      canvas_height_ = previous_height;
      result->Error("window_resize_failed", "Unable to resize the window.");
    }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                    ClientFrameProc, 1, 0);

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (window_channel_) window_channel_->SetMethodCallHandler(nullptr);
  window_channel_.reset();
  tray_icon_.reset();
  vpn_bridge_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::ResizeForLayout() {
  const auto metrics = Metrics(GetHandle(), canvas_width_, canvas_height_);
  const double scale = std::min(1.0, metrics.maximum_scale);
  RECT bounds{};
  GetWindowRect(GetHandle(), &bounds);
  const LONG center_x = bounds.left + (bounds.right - bounds.left) / 2;
  const LONG center_y = bounds.top + (bounds.bottom - bounds.top) / 2;
  const LONG width = OuterWidth(metrics, scale);
  const LONG height = OuterHeight(metrics, scale);
  bounds = {center_x - width / 2, center_y - height / 2,
            center_x - width / 2 + width, center_y - height / 2 + height};
  KeepInWorkArea(&bounds, metrics.work);
  return SetWindowPos(GetHandle(), nullptr, bounds.left, bounds.top, width,
                      height, SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED) !=
         FALSE;
}

void FlutterWindow::ConstrainSizing(WPARAM edge, RECT* bounds) {
  const auto metrics = Metrics(GetHandle(), canvas_width_, canvas_height_);
  RECT origin = sizing_origin_;
  if (!sizing_active_) GetWindowRect(GetHandle(), &origin);
  const double width_scale =
      (bounds->right - bounds->left - metrics.frame_width) / metrics.width;
  const double height_scale =
      (bounds->bottom - bounds->top - metrics.frame_height) / metrics.height;
  const double origin_width_scale =
      (origin.right - origin.left - metrics.frame_width) / metrics.width;
  const double origin_height_scale =
      (origin.bottom - origin.top - metrics.frame_height) / metrics.height;
  const bool horizontal_edge = edge == WMSZ_LEFT || edge == WMSZ_RIGHT;
  const bool vertical_edge = edge == WMSZ_TOP || edge == WMSZ_BOTTOM;
  if (!horizontal_edge && !vertical_edge && sizing_axis_ == 0) {
    sizing_axis_ = std::abs(width_scale - origin_width_scale) >=
                           std::abs(height_scale - origin_height_scale) ? 1 : 2;
  }
  const bool width_driven = horizontal_edge || (!vertical_edge && sizing_axis_ == 1);
  const double scale = std::clamp(width_driven ? width_scale : height_scale,
                                 std::min(0.8, metrics.maximum_scale),
                                 metrics.maximum_scale);
  const LONG width = OuterWidth(metrics, scale);
  const LONG height = OuterHeight(metrics, scale);
  if (edge == WMSZ_LEFT || edge == WMSZ_TOPLEFT || edge == WMSZ_BOTTOMLEFT) {
    bounds->left = bounds->right - width;
  } else {
    if (vertical_edge) {
      bounds->left = origin.left + (origin.right - origin.left - width) / 2;
    }
    bounds->right = bounds->left + width;
  }
  if (edge == WMSZ_TOP || edge == WMSZ_TOPLEFT || edge == WMSZ_TOPRIGHT) {
    bounds->top = bounds->bottom - height;
  } else {
    if (horizontal_edge) {
      bounds->top = origin.top + (origin.bottom - origin.top - height) / 2;
    }
    bounds->bottom = bounds->top + height;
  }
}

void FlutterWindow::ApplyDpiChange(UINT dpi, const RECT& suggested) {
  const auto metrics = Metrics(
      GetHandle(), canvas_width_, canvas_height_, dpi,
      MonitorFromRect(&suggested, MONITOR_DEFAULTTONEAREST));
  const double scale = std::clamp(
      std::min((suggested.right - suggested.left - metrics.frame_width) /
                   metrics.width,
               (suggested.bottom - suggested.top - metrics.frame_height) /
                   metrics.height),
      std::min(0.8, metrics.maximum_scale), metrics.maximum_scale);
  RECT bounds{suggested.left, suggested.top,
              suggested.left + OuterWidth(metrics, scale),
              suggested.top + OuterHeight(metrics, scale)};
  KeepInWorkArea(&bounds, metrics.work);
  SetWindowPos(GetHandle(), nullptr, bounds.left, bounds.top,
               bounds.right - bounds.left, bounds.bottom - bounds.top,
               SWP_NOZORDER | SWP_NOACTIVATE);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Own sizing before plugins: it is a host concern and cannot affect VPN IPC.
  switch (message) {
    case WM_SHOWWINDOW: {
      const bool was_hidden = update_window_hidden_;
      update_window_hidden_ = wparam == FALSE;
      if (was_hidden && !update_window_hidden_ && window_channel_) {
        window_channel_->InvokeMethod("shown", nullptr);
      }
      break;
    }
    case WM_SIZE: {
      const bool was_minimized = update_window_minimized_;
      update_window_minimized_ = wparam == SIZE_MINIMIZED;
      if (was_minimized && !update_window_minimized_ && window_channel_) {
        window_channel_->InvokeMethod("shown", nullptr);
      }
      break;
    }
    case WM_NCCALCSIZE:
      return 0;
    case WM_NCHITTEST: {
      RECT rect{};
      GetWindowRect(hwnd, &rect);
      const UINT dpi = GetDpiForWindow(hwnd);
      const int border = std::max(4, static_cast<int>(std::lround(6.0 * dpi / 96)));
      const int x = GET_X_LPARAM(lparam), y = GET_Y_LPARAM(lparam);
      const bool left = x < rect.left + border;
      const bool right = x >= rect.right - border;
      const bool top = y < rect.top + border;
      const bool bottom = y >= rect.bottom - border;
      if (top && left) return HTTOPLEFT;
      if (top && right) return HTTOPRIGHT;
      if (bottom && left) return HTBOTTOMLEFT;
      if (bottom && right) return HTBOTTOMRIGHT;
      if (left) return HTLEFT;
      if (right) return HTRIGHT;
      if (top) return HTTOP;
      if (bottom) return HTBOTTOM;
      return HTCLIENT;
    }
    case WM_ENTERSIZEMOVE:
      GetWindowRect(hwnd, &sizing_origin_);
      sizing_active_ = true;
      sizing_axis_ = 0;
      break;
    case WM_EXITSIZEMOVE:
      sizing_active_ = false;
      sizing_axis_ = 0;
      break;
    case WM_SIZING:
      ConstrainSizing(wparam, reinterpret_cast<RECT*>(lparam));
      return TRUE;
    case WM_GETMINMAXINFO: {
      const auto metrics = Metrics(hwnd, canvas_width_, canvas_height_);
      const double minimum_scale = std::min(0.8, metrics.maximum_scale);
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      limits->ptMinTrackSize = {OuterWidth(metrics, minimum_scale),
                               OuterHeight(metrics, minimum_scale)};
      limits->ptMaxTrackSize = {OuterWidth(metrics, metrics.maximum_scale),
                               OuterHeight(metrics, metrics.maximum_scale)};
      return 0;
    }
    case WM_DPICHANGED:
      ApplyDpiChange(HIWORD(wparam), *reinterpret_cast<RECT*>(lparam));
      return 0;
    case WM_SYSCOMMAND:
      if ((wparam & 0xfff0) == SC_MAXIMIZE) return 0;
      break;
  }
  if (message == TrayIcon::kExitMessage) {
    if (tray_icon_ && tray_icon_->DeferExitIfMenuOpen()) return 0;
    Destroy();
    return 0;
  }
  if (tray_icon_) {
    const auto result = tray_icon_->HandleMessage(message, wparam, lparam);
    if (result) return *result;
  }
  if (message == VpnBridge::kMessage && vpn_bridge_) {
    vpn_bridge_->Drain();
    return 0;
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
