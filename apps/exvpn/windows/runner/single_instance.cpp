// SPDX-License-Identifier: Apache-2.0
#include "single_instance.h"

#include <sddl.h>

#include <string>
#include <vector>

SingleInstance::~SingleInstance() {
  if (owned_) ReleaseMutex(mutex_);
  if (mutex_) CloseHandle(mutex_);
}

SingleInstance::Result SingleInstance::Acquire() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return Result::unavailable;
  }
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  if (size == 0 || size > 65536) {
    CloseHandle(token);
    return Result::unavailable;
  }
  std::vector<BYTE> buffer(size);
  const bool token_ok = GetTokenInformation(token, TokenUser, buffer.data(),
                                            size, &size) != FALSE;
  CloseHandle(token);
  if (!token_ok) return Result::unavailable;
  LPWSTR sid_text = nullptr;
  if (!ConvertSidToStringSidW(
          reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &sid_text)) {
    return Result::unavailable;
  }
  const std::wstring sid(sid_text);
  LocalFree(sid_text);
  const std::wstring descriptor = L"D:P(A;;GA;;;SY)(A;;GA;;;" + sid + L")";
  PSECURITY_DESCRIPTOR security = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          descriptor.c_str(), SDDL_REVISION_1, &security, nullptr)) {
    return Result::unavailable;
  }
  SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), security, FALSE};
  // Global mutexes (unlike global file mappings) need no
  // SeCreateGlobalPrivilege. Include the user SID because the encrypted store
  // is per-user and shared across Terminal Services sessions. Access failure
  // must not start a writer.
  const std::wstring name = L"Global\\ExVPN.UI.v1." + sid;
  mutex_ = CreateMutexW(&attributes, FALSE, name.c_str());
  LocalFree(security);
  if (!mutex_) return Result::unavailable;
  const DWORD wait = WaitForSingleObject(mutex_, 0);
  if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
    owned_ = true;
    return Result::acquired;
  }
  return wait == WAIT_TIMEOUT ? Result::already_running : Result::unavailable;
}

void SingleInstance::ShowExistingWindow() {
  // An instance in another session cannot be activated from this desktop.
  // A concurrent first launch may not have created its window yet.
  for (int attempt = 0; attempt < 20; ++attempt) {
    const HWND window = FindWindowW(L"EXVPN_RUNNER_WIN32_WINDOW", L"ExVPN");
    if (window) {
      if (IsIconic(window))
        ShowWindowAsync(window, SW_RESTORE);
      else
        ShowWindowAsync(window, SW_SHOW);
      if (!SetForegroundWindow(window)) {
        FLASHWINFO flash{sizeof(FLASHWINFO), window, FLASHW_TRAY, 3, 0};
        FlashWindowEx(&flash);
      }
      return;
    }
    Sleep(100);
  }
}
