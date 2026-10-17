#include "tray_icon.h"

#include <commctrl.h>
#include <flutter/standard_method_codec.h>
#include <strsafe.h>

#include "resource.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT kIconId = 1;
constexpr UINT kOpen = 1;
constexpr UINT kConnect = 2;
constexpr UINT kDisconnect = 3;
constexpr UINT kExit = 4;

const Value* Find(const Map& map, const char* key) {
  const auto it = map.find(Value(key));
  return it == map.end() ? nullptr : &it->second;
}

std::optional<std::wstring> Phase(const std::string& phase) {
  if (phase == "initializing") return L"Проверяем состояние VPN";
  if (phase == "disconnected") return L"VPN отключён";
  if (phase == "requestingPermission") return L"Ожидаем разрешение";
  if (phase == "connecting") return L"Подключаем VPN";
  if (phase == "connected") return L"VPN подключён";
  if (phase == "reconnecting") return L"Восстанавливаем соединение";
  if (phase == "blocked") return L"Трафик заблокирован";
  if (phase == "error") return L"Проверьте состояние VPN";
  return std::nullopt;
}
}  // namespace

TrayIcon::TrayIcon(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "exvpn/tray", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "update") {
      const auto* map = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const Value* phase = map ? Find(*map, "phase") : nullptr;
      const Value* connect = map ? Find(*map, "canConnect") : nullptr;
      const Value* disconnect = map ? Find(*map, "canDisconnect") : nullptr;
      const auto* phase_text = phase ? std::get_if<std::string>(phase) : nullptr;
      const auto* connect_flag = connect ? std::get_if<bool>(connect) : nullptr;
      const auto* disconnect_flag = disconnect ? std::get_if<bool>(disconnect) : nullptr;
      const auto label = phase_text ? Phase(*phase_text) : std::nullopt;
      if (!label || !connect_flag || !disconnect_flag ||
          (*connect_flag && *disconnect_flag)) {
        result->Error("invalid_tray_state", "Invalid tray state.");
        return;
      }
      status_ = *label;
      can_connect_ = *connect_flag;
      can_disconnect_ = *disconnect_flag;
      ready_ = true;
      if (!UpdateIcon()) {
        result->Error("tray_unavailable", "Notification area is unavailable.");
      } else {
        result->Success();
      }
    } else if (call.method_name() == "show") {
      ShowWindow();
      result->Success();
    } else if (call.method_name() == "exit") {
      // Defer destruction until the channel callback has returned.
      result->Success();
      PostMessageW(window_, kExitMessage, 0, 0);
    } else {
      result->NotImplemented();
    }
  });
}

TrayIcon::~TrayIcon() {
  channel_->SetMethodCallHandler(nullptr);
  auto data = Data();
  if (added_) Shell_NotifyIconW(NIM_DELETE, &data);
  if (icon_) DestroyIcon(icon_);
}

NOTIFYICONDATAW TrayIcon::Data() const {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  return data;
}

bool TrayIcon::AddIcon() {
  if (!icon_ && FAILED(LoadIconMetric(GetModuleHandleW(nullptr),
                                     MAKEINTRESOURCEW(IDI_APP_ICON),
                                     LIM_SMALL, &icon_))) return false;
  auto data = Data();
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  data.hIcon = icon_;
  data.uCallbackMessage = kCallback;
  StringCchCopyW(data.szTip, ARRAYSIZE(data.szTip),
                 (L"ExVPN — " + status_).c_str());
  if (!Shell_NotifyIconW(NIM_ADD, &data)) return false;
  data.uVersion = NOTIFYICON_VERSION_4;
  if (!Shell_NotifyIconW(NIM_SETVERSION, &data)) {
    Shell_NotifyIconW(NIM_DELETE, &data);
    return false;
  }
  added_ = true;
  return true;
}

bool TrayIcon::UpdateIcon() {
  if (!added_) return AddIcon();
  auto data = Data();
  data.uFlags = NIF_TIP | NIF_SHOWTIP;
  StringCchCopyW(data.szTip, ARRAYSIZE(data.szTip),
                 (L"ExVPN — " + status_).c_str());
  if (Shell_NotifyIconW(NIM_MODIFY, &data)) return true;
  added_ = false;
  if (AddIcon()) return true;
  ShowWindow();  // Never strand a hidden window when the shell disappears.
  return false;
}

void TrayIcon::ShowWindow() {
  ::ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  if (!SetForegroundWindow(window_)) {
    FLASHWINFO flash{sizeof(FLASHWINFO), window_, FLASHW_TRAY, 2, 0};
    FlashWindowEx(&flash);
  }
}

void TrayIcon::Command(const char* command) {
  if (ready_) channel_->InvokeMethod("command", std::make_unique<Value>(command));
}

bool TrayIcon::DeferExitIfMenuOpen() {
  if (!menu_open_) return false;
  exit_after_menu_ = true;
  EndMenu();
  return true;
}

void TrayIcon::ShowMenu() {
  if (menu_open_) return;
  const auto menu = CreatePopupMenu();
  if (!menu) return;
  menu_open_ = true;
  AppendMenuW(menu, MF_STRING, kOpen, L"Открыть ExVPN");
  SetMenuDefaultItem(menu, kOpen, FALSE);
  AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, status_.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING | (can_connect_ ? MF_ENABLED : MF_GRAYED),
              kConnect, L"Подключить VPN");
  AppendMenuW(menu, MF_STRING | (can_disconnect_ ? MF_ENABLED : MF_GRAYED),
              kDisconnect, L"Отключить VPN");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kExit, L"Выйти из ExVPN…");
  // WM_CONTEXTMENU does not define wParam coordinates in version 4. Use the
  // actual icon rectangle for both pointer and keyboard invocation.
  POINT point{};
  NOTIFYICONIDENTIFIER id{sizeof(NOTIFYICONIDENTIFIER), window_, kIconId, {}};
  RECT rect{};
  if (SUCCEEDED(Shell_NotifyIconGetRect(&id, &rect))) {
    point = {rect.left, rect.top};
  } else {
    GetCursorPos(&point);
  }
  SetForegroundWindow(window_);
  const UINT selected = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
      point.x, point.y, 0, window_, nullptr);
  PostMessageW(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  menu_open_ = false;
  if (exit_after_menu_) {
    PostMessageW(window_, kExitMessage, 0, 0);
    return;
  }
  if (selected == kOpen) ShowWindow();
  else if (selected == kConnect && can_connect_) Command("connect");
  else if (selected == kDisconnect && can_disconnect_) Command("disconnect");
  else if (selected == kExit) Command("exit");
  else {
    auto data = Data();
    Shell_NotifyIconW(NIM_SETFOCUS, &data);
  }
}

std::optional<LRESULT> TrayIcon::HandleMessage(UINT message, WPARAM,
                                              LPARAM lparam) {
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    added_ = false;
    if (icon_) { DestroyIcon(icon_); icon_ = nullptr; }
    if (ready_ && !AddIcon()) ShowWindow();
    return 0;
  }
  if (message == WM_CLOSE && ready_) {
    if (UpdateIcon()) ::ShowWindow(window_, SW_HIDE);
    else Command("exit");  // Visible confirmation + persistence if no tray.
    return 0;
  }
  if (message != kCallback || HIWORD(lparam) != kIconId) return std::nullopt;
  const UINT event = LOWORD(lparam);
  if (event == NIN_SELECT || event == NIN_KEYSELECT) ShowWindow();
  else if (event == WM_CONTEXTMENU) ShowMenu();
  return 0;
}
