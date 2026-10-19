#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <cstdlib>
#include <initializer_list>
#include <string>

#include "flutter_window.h"
#include "single_instance.h"
#include "utils.h"

namespace {
// The local OTA protocol endpoint must bypass inherited network proxies. Only
// this process is changed; Windows/WinINET and user proxy settings are untouched.
bool ConfigureLocalUpdaterProxyBypass() {
  for (const auto* name : {L"NO_PROXY", L"no_proxy"}) {
    const DWORD required = ::GetEnvironmentVariableW(name, nullptr, 0);
    if (required > 32767) return false;
    std::wstring value;
    if (required != 0) {
      value.resize(required);
      const DWORD length = ::GetEnvironmentVariableW(name, value.data(), required);
      if ((length == 0 && required != 1) || length >= required) return false;
      value.resize(length);
    }
    bool present = false;
    size_t offset = 0;
    while (offset <= value.size()) {
      const auto end = value.find(L',', offset);
      const auto count = end == std::wstring::npos ? value.size() - offset : end - offset;
      auto entry = value.substr(offset, count);
      // Pinned ureq compares raw comma-delimited tokens without trimming.
      if (entry == L"127.0.0.1") present = true;
      if (end == std::wstring::npos) break;
      offset = end + 1;
    }
    if (!present) {
      if (!value.empty()) value += L',';
      value += L"127.0.0.1";
    }
    if (value.size() >= 32767 || _wputenv_s(name, value.c_str()) != 0 ||
        !::SetEnvironmentVariableW(name, value.c_str())) return false;
  }
  return true;
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  if (!ConfigureLocalUpdaterProxyBypass()) return EXIT_FAILURE;
  SingleInstance single_instance;
  const auto ownership = single_instance.Acquire();
  if (ownership == SingleInstance::Result::already_running) {
    SingleInstance::ShowExistingWindow();
    return EXIT_SUCCESS;
  }
  if (ownership != SingleInstance::Result::acquired) {
    MessageBoxW(nullptr,
                L"Не удалось получить доступ к хранилищу ExVPN. Закройте "
                L"другой экземпляр приложения и повторите запуск.",
                L"ExVPN", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // FlutterWindow adds the DPI-aware non-client frame around this canvas.
  Win32Window::Size size(440, 760);
  if (!window.Create(L"ExVPN", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
