#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"
#include "vpn_bridge.h"
#include "tray_icon.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  bool ResizeForLayout();
  void ConstrainSizing(WPARAM edge, RECT* bounds);
  void ApplyDpiChange(UINT dpi, const RECT& suggested);

  // Fixed logical client canvases, matching DesktopLayout in Dart.
  int canvas_width_ = 440;
  int canvas_height_ = 760;
  RECT sizing_origin_{};
  bool sizing_active_ = false;
  // Choose a corner's driving axis once per drag, rather than per frame.
  int sizing_axis_ = 0;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<VpnBridge> vpn_bridge_;
  std::unique_ptr<TrayIcon> tray_icon_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
