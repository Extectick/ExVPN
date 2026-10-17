// SPDX-License-Identifier: Apache-2.0
#include "system_proxy.h"

#include <windows.h>
#include <wincrypt.h>
#include <wininet.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/base.h>

#include <array>
#include <cmath>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace {
using namespace winrt::Windows::Data::Json;
constexpr wchar_t kLeaseKey[] = L"Software\\ExVPN\\SystemProxy.v1";
constexpr char kEntropy[] = "ExVPN.SystemProxy.v1";
constexpr DWORD kMaxBytes = 256 * 1024;
struct Key {
  HKEY value = nullptr;
  ~Key() { if (value) RegCloseKey(value); }
};
struct Local {
  BYTE* value = nullptr;
  DWORD length = 0;
  ~Local() {
    if (value) { SecureZeroMemory(value, length); LocalFree(value); }
  }
};
[[noreturn]] void Fail(const char* code) { throw std::runtime_error(code); }

std::wstring String(const JsonObject& object, const wchar_t* field) {
  const auto value = object.GetNamedString(field);
  if (value.size() > 16384 || std::wstring_view(value).find(L'\0') !=
                                  std::wstring_view::npos)
    Fail("proxy_store_unavailable");
  return std::wstring(value);
}
void CheckFields(const JsonObject& object,
                 std::initializer_list<const wchar_t*> fields) {
  if (object.Size() != fields.size()) Fail("proxy_store_unavailable");
  for (const auto* field : fields)
    if (!object.HasKey(field)) Fail("proxy_store_unavailable");
}
JsonObject EncodeSettings(const ProxySettings& settings) {
  JsonObject object;
  object.Insert(L"flags", JsonValue::CreateNumberValue(settings.flags));
  object.Insert(L"server", JsonValue::CreateStringValue(settings.server));
  object.Insert(L"bypass", JsonValue::CreateStringValue(settings.bypass));
  object.Insert(L"pac", JsonValue::CreateStringValue(settings.pac));
  return object;
}
ProxySettings DecodeSettings(const JsonObject& object) {
  CheckFields(object, {L"flags", L"server", L"bypass", L"pac"});
  const auto flags = object.GetNamedNumber(L"flags");
  if (!std::isfinite(flags) || flags < 0 || flags > 15 || std::floor(flags) != flags)
    Fail("proxy_store_unavailable");
  return {static_cast<uint32_t>(flags), String(object, L"server"),
          String(object, L"bypass"), String(object, L"pac")};
}
bool IsOwnedServer(const std::wstring& server) {
  const std::wstring prefix = L"http=127.0.0.1:";
  if (server.size() <= prefix.size() || server.substr(0, prefix.size()) != prefix)
    return false;
  const auto separator = server.find(L';', prefix.size());
  if (separator == std::wstring::npos || separator - prefix.size() > 5)
    return false;
  unsigned port = 0;
  for (size_t i = prefix.size(); i < separator; ++i) {
    if (server[i] < L'0' || server[i] > L'9') return false;
    port = port * 10 + static_cast<unsigned>(server[i] - L'0');
  }
  return port > 0 && port <= 65535 &&
         server == SystemProxy::Server(static_cast<uint16_t>(port));
}
DATA_BLOB Entropy() {
  return {static_cast<DWORD>(sizeof(kEntropy) - 1),
          reinterpret_cast<BYTE*>(const_cast<char*>(kEntropy))};
}

void CheckPerUserPolicy() {
  DWORD per_user = 1, size = sizeof(per_user), type = 0;
  const auto policy = RegGetValueW(
      HKEY_LOCAL_MACHINE,
      L"Software\\Policies\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",
      L"ProxySettingsPerUser", RRF_RT_REG_DWORD, &type, &per_user, &size);
  if ((policy != ERROR_SUCCESS && policy != ERROR_FILE_NOT_FOUND &&
       policy != ERROR_PATH_NOT_FOUND) ||
      (policy == ERROR_SUCCESS && per_user == 0))
    Fail("proxy_settings_conflict");
}

class WindowsProxyBackend final : public ProxySettingsBackend {
 public:
  ProxySettings Read() override {
    CheckPerUserPolicy();
    std::array<INTERNET_PER_CONN_OPTIONW, 4> options{};
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
    INTERNET_PER_CONN_OPTION_LISTW list{};
    list.dwSize = sizeof(list);
    list.dwOptionCount = static_cast<DWORD>(options.size());
    list.pOptions = options.data();
    DWORD size = sizeof(list);
    if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                              &list, &size)) {
      for (size_t i = 1; i < options.size(); ++i)
        GlobalFree(options[i].Value.pszValue);
      Fail("proxy_query_failed");
    }
    ProxySettings result;
    try {
      result.flags = options[0].Value.dwValue;
      if (result.flags > 15) Fail("proxy_query_failed");
      auto copy = [](LPWSTR value) -> std::wstring {
        if (!value) return {};
        const auto length = wcsnlen_s(value, 16385);
        if (length > 16384) Fail("proxy_query_failed");
        return std::wstring(value, length);
      };
      result.server = copy(options[1].Value.pszValue);
      result.bypass = copy(options[2].Value.pszValue);
      result.pac = copy(options[3].Value.pszValue);
    } catch (...) {
      for (size_t i = 1; i < options.size(); ++i)
        GlobalFree(options[i].Value.pszValue);
      throw;
    }
    for (size_t i = 1; i < options.size(); ++i)
      GlobalFree(options[i].Value.pszValue);
    return result;
  }

  void Apply(const ProxySettings& settings) override {
    // Never write machine-wide settings, including policy-selected machine mode.
    CheckPerUserPolicy();
    std::array<INTERNET_PER_CONN_OPTIONW, 4> options{};
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    options[0].Value.dwValue = settings.flags;
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[1].Value.pszValue = const_cast<wchar_t*>(settings.server.c_str());
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    options[2].Value.pszValue = const_cast<wchar_t*>(settings.bypass.c_str());
    options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
    options[3].Value.pszValue = const_cast<wchar_t*>(settings.pac.c_str());
    INTERNET_PER_CONN_OPTION_LISTW list{};
    list.dwSize = sizeof(list);
    list.dwOptionCount = static_cast<DWORD>(options.size());
    list.pOptions = options.data();
    if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                            &list, sizeof(list)) ||
        !InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0) ||
        !InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0))
      Fail("proxy_setup_failed");
  }

  std::optional<ProxyLease> Load() override {
    try {
      Key key;
      auto status = RegOpenKeyExW(HKEY_CURRENT_USER, kLeaseKey, 0,
                                 KEY_QUERY_VALUE, &key.value);
      if (status == ERROR_FILE_NOT_FOUND) return std::nullopt;
      if (status != ERROR_SUCCESS) Fail("proxy_store_unavailable");
      DWORD type = 0, size = 0;
      status = RegQueryValueExW(key.value, L"Lease", nullptr, &type, nullptr, &size);
      if (status == ERROR_FILE_NOT_FOUND) return std::nullopt;
      if (status != ERROR_SUCCESS || type != REG_BINARY || size == 0 ||
          size > kMaxBytes)
        Fail("proxy_store_unavailable");
      std::vector<BYTE> encrypted(size);
      if (RegQueryValueExW(key.value, L"Lease", nullptr, &type,
                           encrypted.data(), &size) != ERROR_SUCCESS ||
          type != REG_BINARY || size == 0 || size > encrypted.size())
        Fail("proxy_store_unavailable");
      DATA_BLOB input{size, encrypted.data()}, output{}, entropy = Entropy();
      if (!CryptUnprotectData(&input, nullptr, &entropy, nullptr, nullptr,
                              CRYPTPROTECT_UI_FORBIDDEN, &output))
        Fail("proxy_store_unavailable");
      Local plain{output.pbData, output.cbData};
      if (plain.length == 0 || plain.length > kMaxBytes)
        Fail("proxy_store_unavailable");
      const std::string json(reinterpret_cast<char*>(plain.value), plain.length);
      const auto object = JsonObject::Parse(winrt::to_hstring(json));
      CheckFields(object, {L"version", L"original", L"current", L"previous"});
      if (object.GetNamedNumber(L"version") != 1)
        Fail("proxy_store_unavailable");
      ProxyLease lease{DecodeSettings(object.GetNamedObject(L"original")),
                       String(object, L"current"), String(object, L"previous")};
      if (!IsOwnedServer(lease.current_server) ||
          (!lease.previous_server.empty() && !IsOwnedServer(lease.previous_server)))
        Fail("proxy_store_unavailable");
      return lease;
    } catch (...) { Fail("proxy_store_unavailable"); }
  }

  void Save(const std::optional<ProxyLease>& lease) override {
    try {
      Key key;
      if (RegCreateKeyExW(HKEY_CURRENT_USER, kLeaseKey, 0, nullptr, 0,
                          KEY_QUERY_VALUE | KEY_SET_VALUE, nullptr, &key.value,
                          nullptr) != ERROR_SUCCESS)
        Fail("proxy_store_unavailable");
      if (!lease) {
        const auto status = RegDeleteValueW(key.value, L"Lease");
        if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND)
          Fail("proxy_store_unavailable");
      } else {
        JsonObject object;
        object.Insert(L"version", JsonValue::CreateNumberValue(1));
        object.Insert(L"original", EncodeSettings(lease->original));
        object.Insert(L"current", JsonValue::CreateStringValue(lease->current_server));
        object.Insert(L"previous", JsonValue::CreateStringValue(lease->previous_server));
        auto json = winrt::to_string(object.Stringify());
        if (json.empty() || json.size() > kMaxBytes)
          Fail("proxy_store_unavailable");
        DATA_BLOB input{static_cast<DWORD>(json.size()),
                        reinterpret_cast<BYTE*>(json.data())};
        DATA_BLOB output{}, entropy = Entropy();
        if (!CryptProtectData(&input, L"ExVPN system proxy lease", &entropy,
                               nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output))
          Fail("proxy_store_unavailable");
        Local encrypted{output.pbData, output.cbData};
        SecureZeroMemory(json.data(), json.size());
        if (encrypted.length > kMaxBytes ||
            RegSetValueExW(key.value, L"Lease", 0, REG_BINARY, encrypted.value,
                           encrypted.length) != ERROR_SUCCESS)
          Fail("proxy_store_unavailable");
      }
      if (RegFlushKey(key.value) != ERROR_SUCCESS) Fail("proxy_store_unavailable");
    } catch (...) { Fail("proxy_store_unavailable"); }
  }
};
}  // namespace

std::unique_ptr<ProxySettingsBackend> CreateWindowsProxyBackend() {
  return std::make_unique<WindowsProxyBackend>();
}
