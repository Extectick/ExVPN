#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <optional>
#include <string>

// Window-thread-only shell adapter. VPN commands always return through Dart's
// existing controller and authenticated service bridge.
class TrayIcon {
 public:
  static constexpr UINT kExitMessage = WM_APP + 73;
  TrayIcon(flutter::BinaryMessenger* messenger, HWND window);
  ~TrayIcon();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);
  // A native popup owns a nested message loop. Defer destruction until it ends.
  bool DeferExitIfMenuOpen();

 private:
  static constexpr UINT kCallback = WM_APP + 72;
  bool AddIcon();
  bool UpdateIcon();
  void ShowWindow();
  void ShowMenu();
  void Command(const char* command);
  NOTIFYICONDATAW Data() const;

  HWND window_;
  HICON icon_ = nullptr;
  UINT taskbar_created_ = 0;
  bool added_ = false;
  bool ready_ = false;
  bool can_connect_ = false;
  bool can_disconnect_ = false;
  bool menu_open_ = false;
  bool exit_after_menu_ = false;
  std::wstring status_ = L"Проверяем состояние VPN";
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_TRAY_ICON_H_
