// SPDX-License-Identifier: Apache-2.0
#include "vpn_bridge.h"
#include "system_proxy.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/base.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cwchar>
#include <cwctype>
#include <cstring>
#include <map>
#include <regex>
#include <set>
#include <stdexcept>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using namespace winrt::Windows::Data::Json;
constexpr wchar_t kPipe[] = L"\\\\.\\pipe\\ExVPN.Control.v1";
constexpr uint32_t kMaxFrame = (1 << 20) + 8192;
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  ~Handle() {
    if (value != INVALID_HANDLE_VALUE && value != nullptr) CloseHandle(value);
  }
};
struct ServiceHandle {
  SC_HANDLE value = nullptr;
  ~ServiceHandle() {
    if (value) CloseServiceHandle(value);
  }
};
[[noreturn]] void Fail(const char* code) { throw std::runtime_error(code); }
const Value& Field(const Value& value, const char* key) {
  const auto* map = std::get_if<Map>(&value);
  if (!map) Fail("invalid_native_request");
  auto it = map->find(Value(key));
  if (it == map->end()) Fail("invalid_native_request");
  return it->second;
}
IJsonValue Json(const Value& v, int depth = 0) {
  if (depth > 16) Fail("invalid_native_request");
  if (const auto* p = std::get_if<std::string>(&v))
    return JsonValue::CreateStringValue(winrt::to_hstring(*p));
  if (const auto* p = std::get_if<int32_t>(&v))
    return JsonValue::CreateNumberValue(*p);
  if (const auto* p = std::get_if<int64_t>(&v))
    return JsonValue::CreateNumberValue(static_cast<double>(*p));
  if (const auto* p = std::get_if<bool>(&v))
    return JsonValue::CreateBooleanValue(*p);
  if (const auto* p = std::get_if<Map>(&v)) {
    JsonObject object;
    for (const auto& item : *p) {
      const auto* key = std::get_if<std::string>(&item.first);
      if (!key) Fail("invalid_native_request");
      object.Insert(winrt::to_hstring(*key), Json(item.second, depth + 1));
    }
    return object;
  }
  if (const auto* p = std::get_if<List>(&v)) {
    JsonArray array;
    for (const auto& item : *p) array.Append(Json(item, depth + 1));
    return array;
  }
  Fail("invalid_native_request");
}
Value Status(const JsonObject& s) {
  auto phase = winrt::to_string(s.GetNamedString(L"state"));
  const std::set<std::string> phases = {"disconnected", "connecting",
                                        "connected",    "reconnecting",
                                        "blocked",      "error"};
  if (!phases.count(phase)) Fail("ipc_invalid_response");
  const auto mode = winrt::to_string(s.GetNamedString(L"mode", L"vpn"));
  if (mode != "vpn" && mode != "proxy") Fail("ipc_invalid_response");
  const auto capabilities = s.GetNamedObject(L"capabilities");
  Map m{{Value("phase"), Value(phase)},
        {Value("mode"), Value(mode)},
        {Value("systemProxySupported"),
         Value(capabilities.GetNamedBoolean(L"systemProxy", false))},
        {Value("automaticSelection"),
         Value(s.GetNamedBoolean(L"automaticSelection", false))},
        {Value("processCrashProtection"),
         Value(mode == "vpn" && capabilities.GetNamedBoolean(L"verified") &&
               s.GetNamedBoolean(L"persistentGuardActive", false))}};
  if (s.HasKey(L"activeProfileId"))
    m.emplace(Value("activeProfileId"),
              Value(winrt::to_string(s.GetNamedString(L"activeProfileId"))));
  if (s.HasKey(L"connectedAt"))
    m.emplace(
        Value("connectedAt"),
        Value(static_cast<int64_t>(s.GetNamedNumber(L"connectedAt")) * 1000));
  if (phase == "error" || phase == "blocked" || phase == "reconnecting")
    m.emplace(Value("errorCode"),
              Value(winrt::to_string(s.GetNamedString(L"code"))));
  return Value(m);
}
Value Unavailable(const char* code, const std::string& mode,
                  bool proxy_supported, bool cleanup) {
  return Value(Map{{Value("phase"), Value("error")},
                   {Value("mode"), Value(mode)},
                   {Value("systemProxySupported"), Value(proxy_supported)},
                   {Value("cleanupRequired"), Value(cleanup)},
                   {Value("processCrashProtection"), Value(false)},
                   {Value("errorCode"), Value(code)}});
}
Value Traffic(const JsonObject& traffic) {
  Map value;
  for (const auto* key : {L"uploadBytes", L"downloadBytes"}) {
    const auto bytes = traffic.GetNamedNumber(key);
    if (!std::isfinite(bytes) || bytes < 0 || bytes > 9007199254740991.0 ||
        std::floor(bytes) != bytes)
      Fail("ipc_invalid_response");
    value.emplace(Value(winrt::to_string(key)),
                  Value(static_cast<int64_t>(bytes)));
  }
  return Value(value);
}
std::wstring ProcessPath(HANDLE process) {
  std::wstring path(32768, L'\0');
  DWORD n = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &n))
    Fail("ipc_peer_unavailable");
  path.resize(n);
  return path;
}
void CheckServer(HANDLE pipe, Handle& process) {
  ULONG pid = 0;
  if (!GetNamedPipeServerProcessId(pipe, &pid)) Fail("ipc_peer_unavailable");
  ServiceHandle manager{OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT)};
  if (!manager.value) Fail("ipc_peer_unavailable");
  ServiceHandle service{
      OpenServiceW(manager.value, L"ExVPNService",
                   SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG)};
  if (!service.value) Fail("ipc_access_denied");
  SERVICE_STATUS_PROCESS state{};
  DWORD bytes = 0;
  if (!QueryServiceStatusEx(service.value, SC_STATUS_PROCESS_INFO,
                            reinterpret_cast<BYTE*>(&state), sizeof(state),
                            &bytes) ||
      state.dwProcessId != pid || state.dwCurrentState != SERVICE_RUNNING)
    Fail("ipc_access_denied");
  DWORD needed = 0;
  QueryServiceConfigW(service.value, nullptr, 0, &needed);
  if (needed == 0 || needed > 65536) Fail("ipc_access_denied");
  std::vector<BYTE> config(needed);
  auto* service_config =
      reinterpret_cast<QUERY_SERVICE_CONFIGW*>(config.data());
  if (!QueryServiceConfigW(service.value, service_config, needed, &needed) ||
      _wcsicmp(service_config->lpServiceStartName, L"LocalSystem") != 0)
    Fail("ipc_access_denied");
  process.value = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process.value) Fail("ipc_peer_unavailable");
  PWSTR program_files = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_ProgramFiles, 0, nullptr,
                                  &program_files)))
    Fail("ipc_peer_unavailable");
  const std::wstring expected =
      std::wstring(program_files) + L"\\ExVPN Service\\exvpn-service.exe";
  CoTaskMemFree(program_files);
  if (_wcsicmp(ProcessPath(process.value).c_str(), expected.c_str()) != 0)
    Fail("ipc_access_denied");
}
void Transfer(HANDLE pipe, void* data, DWORD size, bool write,
              ULONGLONG deadline) {
  auto* current = static_cast<BYTE*>(data);
  while (size) {
    Handle event{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    if (!event.value) Fail("ipc_failed");
    OVERLAPPED op{};
    op.hEvent = event.value;
    DWORD count = 0;
    BOOL ok = write ? WriteFile(pipe, current, size, &count, &op)
                    : ReadFile(pipe, current, size, &count, &op);
    if (!ok) {
      if (GetLastError() != ERROR_IO_PENDING) Fail("service_unavailable");
      const auto now = GetTickCount64();
      DWORD wait = now >= deadline ? 0 : static_cast<DWORD>(deadline - now);
      if (WaitForSingleObject(event.value, wait) != WAIT_OBJECT_0) {
        CancelIoEx(pipe, &op);
        GetOverlappedResult(pipe, &op, &count, TRUE);
        Fail("ipc_timeout");
      }
      if (!GetOverlappedResult(pipe, &op, &count, FALSE))
        Fail("service_unavailable");
    }
    if (!count || count > size) Fail("ipc_invalid_response");
    current += count;
    size -= count;
  }
}
JsonObject Request(const std::string& command, const Value* profile,
                   const List& exclusions, const std::string& mode = "",
                   const Value* application_routing = nullptr,
                   const Value* automatic_profiles = nullptr,
                   const bool* protection_enabled = nullptr) {
  Handle pipe{CreateFileW(
      kPipe, 0x12019b, 0, nullptr, OPEN_EXISTING,
      FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
      nullptr)};
  if (pipe.value == INVALID_HANDLE_VALUE) Fail("service_unavailable");
  Handle process;
  CheckServer(pipe.value, process);
  JsonObject request;
  request.Insert(L"version", JsonValue::CreateNumberValue(1));
  request.Insert(L"id", JsonValue::CreateStringValue(L"flutter"));
  request.Insert(L"command",
                 JsonValue::CreateStringValue(winrt::to_hstring(command)));
  if (profile) request.Insert(L"profile", Json(*profile));
  if (!mode.empty())
    request.Insert(L"mode", JsonValue::CreateStringValue(winrt::to_hstring(mode)));
  if (command == "setExclusions")
    request.Insert(L"exclusions", Json(Value(exclusions)));
  if (application_routing)
    request.Insert(L"applicationRouting", Json(*application_routing));
  if (automatic_profiles)
    request.Insert(L"automaticProfiles", Json(*automatic_profiles));
  if (protection_enabled)
    request.Insert(L"enabled", JsonValue::CreateBooleanValue(*protection_enabled));
  std::string body = winrt::to_string(request.Stringify());
  if (body.empty() || body.size() > kMaxFrame) Fail("invalid_native_request");
  uint32_t size = static_cast<uint32_t>(body.size());
  const auto deadline = GetTickCount64() + 25000;
  Transfer(pipe.value, &size, 4, true, deadline);
  Transfer(pipe.value, body.data(), size, true, deadline);
  Transfer(pipe.value, &size, 4, false, deadline);
  if (size == 0 || size > kMaxFrame) Fail("ipc_invalid_response");
  std::string response(size, '\0');
  Transfer(pipe.value, response.data(), size, false, deadline);
  JsonObject parsed;
  if (!JsonObject::TryParse(winrt::to_hstring(response), parsed) ||
      parsed.GetNamedNumber(L"version") != 1 ||
      parsed.GetNamedString(L"id") != L"flutter")
    Fail("ipc_invalid_response");
  return parsed;
}
std::wstring ApplicationFamilyKey(std::wstring path) {
  std::replace(path.begin(), path.end(), L'\\', L'/');
  std::transform(path.begin(), path.end(), path.begin(), ::towlower);
  const std::wregex discord(
      LR"(^([a-z]:/users/[^/]+/appdata/local/(discord|discordptb|discordcanary))/app-(0|[1-9][0-9]{0,8})(\.(0|[1-9][0-9]{0,8})){1,3}/(discord|discordptb|discordcanary)\.exe$)");
  std::wsmatch match;
  if (std::regex_match(path, match, discord) && match[2].str() == match[6].str())
    return match[1].str() + L"/" + match[6].str() + L".exe";
  return path;
}

std::wstring ApplicationId(const std::wstring& path) {
  auto normalized = path;
  std::replace(normalized.begin(), normalized.end(), L'\\', L'/');
  std::transform(normalized.begin(), normalized.end(), normalized.begin(), ::towlower);
  const auto family = ApplicationFamilyKey(path);
  return family == normalized ? path : family;
}

bool RealApplicationPath(const std::wstring& path);

std::wstring FamilyIconImage(const std::wstring& id) {
  const auto key = ApplicationFamilyKey(id);
  const std::wregex anchor(LR"(^([a-z]:/users/[^/]+/appdata/local/(discord|discordptb|discordcanary))/(discord|discordptb|discordcanary)\.exe$)");
  std::wsmatch match;
  if (!std::regex_match(key, match, anchor) || match[2].str() != match[3].str()) return id;
  const std::wregex version(LR"(^app-(0|[1-9][0-9]{0,8})(\.(0|[1-9][0-9]{0,8})){1,3}$)");
  const auto root = match[1].str();
  WIN32_FIND_DATAW entry{};
  HANDLE search = FindFirstFileW((root + L"/app-*").c_str(), &entry);
  if (search == INVALID_HANDLE_VALUE) return L"";
  std::wstring found;
  std::vector<unsigned long> best;
  size_t count = 0;
  do {
    if (++count > 512) { found.clear(); break; }
    const std::wstring name(entry.cFileName);
    if (!(entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (entry.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) || !std::regex_match(name, version)) continue;
    const auto image = root + L"/" + name + L"/" + match[3].str() + L".exe";
    if (!RealApplicationPath(image)) continue;
    std::vector<unsigned long> numbers(4, 0);
    size_t start = 4;
    for (size_t i = 0; i < 4 && start < name.size(); ++i) {
      const auto end = name.find(L'.', start);
      numbers[i] = std::stoul(name.substr(start, end - start));
      if (end == std::wstring::npos) break;
      start = end + 1;
    }
    if (found.empty() || best < numbers) { found = image; best = numbers; }
  } while (FindNextFileW(search, &entry));
  FindClose(search);
  return found;
}

bool RealApplicationPath(const std::wstring& path) {
  if (path.size() < 7 || path.size() > 1024 || path[1] != L':' ||
      path.find(L"/../") != std::wstring::npos || path.find(L"/./") != std::wstring::npos)
    return false;
  for (size_t at = 3; at <= path.size(); ++at) {
    if (at != path.size() && path[at] != L'/' && path[at] != L'\\') continue;
    const auto attributes = GetFileAttributesW(path.substr(0, at).c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
      return false;
  }
  Handle file{CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
                        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr)};
  if (file.value == INVALID_HANDLE_VALUE) return false;
  std::array<wchar_t, 32768> final_path{};
  const auto size = GetFinalPathNameByHandleW(file.value, final_path.data(),
                                             static_cast<DWORD>(final_path.size()), 0);
  if (!size || size >= final_path.size()) return false;
  std::wstring resolved(final_path.data(), size);
  if (resolved.rfind(L"\\\\?\\", 0) == 0) resolved.erase(0, 4);
  std::wstring expected = path;
  std::replace(expected.begin(), expected.end(), L'/', L'\\');
  return _wcsicmp(expected.c_str(), resolved.c_str()) == 0;
}

std::vector<uint8_t> RasterApplicationIcon(HICON icon, bool white) {
  BITMAPINFO bitmap{};
  bitmap.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap.bmiHeader.biWidth = 64;
  bitmap.bmiHeader.biHeight = -64;
  bitmap.bmiHeader.biPlanes = 1;
  bitmap.bmiHeader.biBitCount = 32;
  bitmap.bmiHeader.biCompression = BI_RGB;
  HDC dc = CreateCompatibleDC(nullptr);
  if (!dc) return {};
  void* pixels = nullptr;
  HBITMAP dib = CreateDIBSection(dc, &bitmap, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (!dib || !pixels) { if (dib) DeleteObject(dib); DeleteDC(dc); return {}; }
  auto previous = SelectObject(dc, dib);
  std::memset(pixels, white ? 255 : 0, 64 * 64 * 4);
  const bool drawn = DrawIconEx(dc, 0, 0, icon, 64, 64, 0, nullptr, DI_NORMAL) != FALSE;
  GdiFlush();
  std::vector<uint8_t> result;
  if (drawn) result.assign(static_cast<uint8_t*>(pixels), static_cast<uint8_t*>(pixels) + 64 * 64 * 4);
  SelectObject(dc, previous);
  DeleteObject(dib);
  DeleteDC(dc);
  return result;
}

Value ApplicationIcon(const std::wstring& path) {
  if (!RealApplicationPath(path)) return Value();
  HICON icon = nullptr;
  if (FAILED(SHDefExtractIconW(path.c_str(), 0, 0, &icon, nullptr, 64)) || !icon)
    return Value();
  auto black = RasterApplicationIcon(icon, false);
  auto white = RasterApplicationIcon(icon, true);
  DestroyIcon(icon);
  if (black.size() != 64 * 64 * 4 || white.size() != black.size()) return Value();
  // Reconstruct alpha from two backgrounds, including legacy icons without an
  // alpha channel. Pixels remain premultiplied BGRA for the system PNG encoder.
  for (size_t i = 0; i < black.size(); i += 4) {
    int delta = 0;
    for (size_t c = 0; c < 3; ++c)
      delta = std::max(delta, static_cast<int>(white[i + c]) - static_cast<int>(black[i + c]));
    black[i + 3] = static_cast<uint8_t>(255 - delta);
  }
  using namespace winrt::Windows::Graphics::Imaging;
  using namespace winrt::Windows::Storage::Streams;
  InMemoryRandomAccessStream stream;
  auto encoder = BitmapEncoder::CreateAsync(BitmapEncoder::PngEncoderId(), stream).get();
  encoder.SetPixelData(BitmapPixelFormat::Bgra8, BitmapAlphaMode::Premultiplied,
                       64, 64, 96, 96, black);
  encoder.FlushAsync().get();
  if (!stream.Size() || stream.Size() > 64 * 1024) return Value();
  DataReader reader(stream.GetInputStreamAt(0));
  const auto size = static_cast<uint32_t>(stream.Size());
  if (reader.LoadAsync(size).get() != size) return Value();
  std::vector<uint8_t> png(size);
  reader.ReadBytes(png);
  return Value(png);
}

Value Applications(std::map<std::string, std::wstring>& images) {
  Handle snapshot{CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)};
  if (snapshot.value == INVALID_HANDLE_VALUE) Fail("applications_unavailable");
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  List list;
  std::set<std::wstring> seen;
  for (BOOL ok = Process32FirstW(snapshot.value, &entry); ok;
       ok = Process32NextW(snapshot.value, &entry)) {
    if (entry.th32ProcessID == GetCurrentProcessId()) continue;
    Handle p{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                         entry.th32ProcessID)};
    if (!p.value) continue;
    try {
      auto path = ProcessPath(p.value);
      std::replace(path.begin(), path.end(), L'\\', L'/');
      if (!RealApplicationPath(path)) continue;
      auto lower = ApplicationFamilyKey(path);
      if (!seen.insert(lower).second) continue;
      const auto id = ApplicationId(path);
      images[winrt::to_string(id)] = path;
      list.emplace_back(Map{
          {Value("id"), Value(winrt::to_string(id))},
          {Value("displayName"), Value(winrt::to_string(entry.szExeFile))}});
    } catch (...) {
    }
  }
  return Value(list);
}
}  // namespace

VpnBridge::VpnBridge(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  methods_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "exvpn/vpn", codec);
  states_ = std::make_unique<flutter::EventChannel<Value>>(
      messenger, "exvpn/vpn_state", codec);
  stats_ = std::make_unique<flutter::EventChannel<Value>>(
      messenger, "exvpn/vpn_stats", codec);
  methods_->SetMethodCallHandler(
      [this](const auto& call, std::unique_ptr<Result> result) {
        Enqueue(Job{call.method_name(),
                    call.arguments() ? *call.arguments() : Value(),
                    std::move(result)});
      });
  states_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<Value>>(
          [this](const Value*,
                 std::unique_ptr<flutter::EventSink<Value>>&& sink) {
            state_sink_ = std::move(sink);
            Enqueue(Job{"getStatus", Value(), nullptr});
            return nullptr;
          },
          [this](const Value*) {
            state_sink_.reset();
            return nullptr;
          }));
  stats_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<Value>>(
          [this](const Value*,
                 std::unique_ptr<flutter::EventSink<Value>>&& sink) {
            stats_sink_ = std::move(sink);
            Enqueue(Job{"getStatus", Value(), nullptr});
            return nullptr;
          },
          [this](const Value*) {
            stats_sink_.reset();
            return nullptr;
          }));
  worker_ = std::thread([this] { Work(); });
}
VpnBridge::~VpnBridge() {
  methods_->SetMethodCallHandler(nullptr);
  states_->SetStreamHandler(nullptr);
  stats_->SetStreamHandler(nullptr);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
    jobs_.clear();
  }
  wake_.notify_all();
  if (worker_.joinable()) worker_.join();
}
void VpnBridge::Enqueue(Job job) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopping_ || jobs_.size() >= 16) {
    if (job.result)
      job.result->Error("operation_in_progress",
                        "Native request queue is busy");
    return;
  }
  jobs_.push_back(std::move(job));
  wake_.notify_one();
}
void VpnBridge::Work() {
  winrt::init_apartment();
  List exclusions;
  std::map<std::string, std::wstring> application_images;
  SystemProxy system_proxy(CreateWindowsProxyBackend());
  std::string last_mode = "vpn";
  bool proxy_supported = false;
  bool status_seen = false;
  bool awaiting_explicit_proxy = false;
  for (;;) {
    Job job;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      wake_.wait_for(lock, std::chrono::seconds(1),
                     [this] { return stopping_ || !jobs_.empty(); });
      if (stopping_) break;
      if (jobs_.empty()) {
        job.method = "getStatus";
      } else {
        job = std::move(jobs_.front());
        jobs_.pop_front();
      }
    }
    Completion completion;
    completion.result = std::move(job.result);
    try {
      if (job.method == "coreVersion") {
        const auto response = Request("status", nullptr, {});
        completion.value = Value(winrt::to_string(
            response.GetNamedObject(L"status").GetNamedString(L"coreVersion")));
      } else if (job.method == "listApplications") {
        completion.value = Applications(application_images);
      } else if (job.method == "getApplicationIcon") {
        const auto* arguments = std::get_if<Map>(&job.arguments);
        const auto* id = std::get_if<std::string>(&Field(job.arguments, "application"));
        if (!arguments || arguments->size() != 1 || !id || id->size() > 1024)
          Fail("application_icon_unavailable");
        const auto image = application_images.find(*id);
        if (image == application_images.end()) completion.value = Value();
        else {
          try { completion.value = ApplicationIcon(image->second.empty()
              ? FamilyIconImage(winrt::to_hstring(*id).c_str()) : image->second); }
          catch (...) { completion.value = Value(); }
        }
      } else if (job.method == "getConnectionProtection" ||
                 job.method == "setConnectionProtection") {
        const auto* arguments = std::get_if<Map>(&job.arguments);
        const bool* enabled = nullptr;
        if (job.method == "setConnectionProtection") {
          if (!arguments || arguments->size() != 1)
            Fail("invalid_native_request");
          enabled = std::get_if<bool>(&Field(job.arguments, "enabled"));
          if (!enabled) Fail("invalid_native_request");
        } else if (!std::holds_alternative<std::monostate>(job.arguments) &&
                   (!arguments || !arguments->empty())) {
          Fail("invalid_native_request");
        }
        auto response = Request(job.method, nullptr, {}, "", nullptr, nullptr,
                                enabled);
        if (!response.GetNamedBoolean(L"ok"))
          throw std::runtime_error(winrt::to_string(response.GetNamedString(L"code")));
        const auto value = response.GetNamedObject(L"connectionProtection");
        if (value.Size() != 4 ||
            value.GetNamedValue(L"supported").ValueType() != JsonValueType::Boolean ||
            value.GetNamedValue(L"enabled").ValueType() != JsonValueType::Boolean ||
            value.GetNamedValue(L"active").ValueType() != JsonValueType::Boolean ||
            value.GetNamedValue(L"systemManaged").ValueType() != JsonValueType::Boolean ||
            value.GetNamedBoolean(L"systemManaged"))
          Fail("ipc_invalid_response");
        completion.value = Value(Map{
            {Value("supported"), Value(value.GetNamedBoolean(L"supported"))},
            {Value("enabled"), Value(value.GetNamedBoolean(L"enabled"))},
            {Value("active"), Value(value.GetNamedBoolean(L"active"))},
            {Value("systemManaged"), Value(false)}});
      } else if (job.method == "openSystemProtectionSettings") {
        Fail("system_protection_settings_unsupported");
      } else if (job.method == "setApplicationRouting") {
        const auto* arguments = std::get_if<Map>(&job.arguments);
        const auto* mode = std::get_if<std::string>(&Field(job.arguments, "mode"));
        const auto* applications = std::get_if<List>(&Field(job.arguments, "applications"));
        if (!arguments || arguments->size() != 2 || !mode ||
            (*mode != "disabled" && *mode != "exclude" && *mode != "include") ||
            !applications || applications->size() > 128)
          Fail("application_routing_rejected");
        for (const auto& app : *applications) {
          const auto* path = std::get_if<std::string>(&app);
          if (!path || path->size() < 7 || path->size() > 1024)
            Fail("application_routing_rejected");
        }
        auto response = Request("setApplicationRouting", nullptr, {}, "", &job.arguments);
        if (!response.GetNamedBoolean(L"ok"))
          throw std::runtime_error(winrt::to_string(response.GetNamedString(L"code")));
      } else if (job.method == "getApplicationRouting") {
        auto response = Request("getApplicationRouting", nullptr, {});
        if (!response.GetNamedBoolean(L"ok"))
          throw std::runtime_error(winrt::to_string(response.GetNamedString(L"code")));
        const auto routing = response.GetNamedObject(L"applicationRouting");
        const auto mode = winrt::to_string(routing.GetNamedString(L"mode"));
        const auto applications = routing.GetNamedArray(L"applications");
        if ((mode != "disabled" && mode != "exclude" && mode != "include") || applications.Size() > 128)
          Fail("ipc_invalid_response");
        List ids;
        for (const auto& id : applications) {
          const auto value = winrt::to_string(id.GetString());
          ids.emplace_back(value);
          application_images.try_emplace(value, L"");
        }
        completion.value = Value(Map{{Value("mode"), Value(mode)}, {Value("applications"), Value(ids)}});
      } else if (job.method == "setExclusions") {
        const auto& value = Field(job.arguments, "applications");
        const auto* applications = std::get_if<List>(&value);
        if (!applications || applications->size() > 128)
          Fail("invalid_native_request");
        for (const auto& app : *applications) {
          const auto* path = std::get_if<std::string>(&app);
          if (!path || path->size() < 7 || path->size() > 1024)
            Fail("invalid_native_request");
        }
        auto response = Request("setExclusions", nullptr, *applications);
        if (!response.GetNamedBoolean(L"ok"))
          throw std::runtime_error(
              winrt::to_string(response.GetNamedString(L"code")));
      } else if (job.method == "getExclusions") {
        auto response = Request("getExclusions", nullptr, {});
        if (!response.GetNamedBoolean(L"ok"))
          throw std::runtime_error(
              winrt::to_string(response.GetNamedString(L"code")));
        List result;
        if (response.HasKey(L"exclusions")) {
          for (const auto& path : response.GetNamedArray(L"exclusions"))
            result.emplace_back(winrt::to_string(path.GetString()));
        }
        completion.value = Value(result);
      } else if (job.method == "getStatus" || job.method == "connect" ||
                 job.method == "reconnect" ||
                 job.method == "clearAutomaticSelection" ||
                 job.method == "disconnect" || job.method == "probe") {
        const Value* profile = nullptr;
        const Value* automatic_profiles = nullptr;
        std::string mode;
        if (job.method == "connect" || job.method == "reconnect") {
          mode = "vpn";
          const auto* arguments = std::get_if<Map>(&job.arguments);
          if (!arguments) Fail("invalid_native_request");
          const auto group = arguments->find(Value("automaticProfiles"));
          if (group != arguments->end()) {
            const auto* candidates = std::get_if<List>(&group->second);
            if (!candidates || candidates->empty() || candidates->size() > 32)
              Fail("invalid_native_request");
            for (const auto& candidate : *candidates)
              if (!std::get_if<Map>(&candidate)) Fail("invalid_native_request");
            automatic_profiles = &group->second;
          }
          const auto found = arguments->find(Value("mode"));
          if (found != arguments->end()) {
            const auto* requested = std::get_if<std::string>(&found->second);
            if (!requested || (*requested != "vpn" && *requested != "proxy"))
              Fail("mode_invalid");
            mode = *requested;
          }
        }
        if (job.method == "connect" || job.method == "reconnect" ||
            job.method == "probe")
          profile = &Field(job.arguments, "profile");
        std::string restore_error;
        if (job.method == "disconnect") {
          awaiting_explicit_proxy = false;
          try { system_proxy.Restore(); }
          catch (const std::runtime_error& error) { restore_error = error.what(); }
          catch (...) { restore_error = "proxy_restore_failed"; }
        }
        auto response =
            Request(job.method == "getStatus" ? "status" : job.method, profile,
                    exclusions, mode, nullptr, automatic_profiles);
        const auto native_status = response.GetNamedObject(L"status");
        completion.status = Status(native_status);
        last_mode = winrt::to_string(native_status.GetNamedString(L"mode", L"vpn"));
        status_seen = true;
        proxy_supported = native_status.GetNamedObject(L"capabilities")
            .GetNamedBoolean(L"systemProxy", false);
        if (!response.GetNamedBoolean(L"ok"))
          throw std::runtime_error(
              winrt::to_string(response.GetNamedString(L"code")));
        if (job.method == "connect" || job.method == "reconnect")
          awaiting_explicit_proxy = mode == "proxy";
        if (!restore_error.empty()) Fail(restore_error.c_str());
        const auto state = native_status.GetNamedString(L"state");
        if (last_mode == "proxy" && state == L"connected") {
          const auto port = native_status.GetNamedNumber(L"proxyPort", 0);
          if (!proxy_supported || !std::isfinite(port) || port < 1 ||
              port > 65535 || std::floor(port) != port)
            Fail("proxy_invalid_endpoint");
          system_proxy.Enable(static_cast<uint16_t>(port), awaiting_explicit_proxy);
          awaiting_explicit_proxy = false;
        } else if (state == L"disconnected" ||
                   (last_mode == "vpn" &&
                    native_status.GetNamedBoolean(L"guardActive"))) {
          system_proxy.Restore();
          if (state == L"disconnected") awaiting_explicit_proxy = false;
        }
        if (job.method == "getStatus") {
          completion.value = completion.status;
          try {
            auto counters = Request("stats", nullptr, {});
            if (!counters.GetNamedBoolean(L"ok"))
              Fail("statistics_unavailable");
            completion.traffic = Traffic(counters.GetNamedObject(L"traffic"));
          } catch (...) {
            completion.traffic_error = "statistics_unavailable";
          }
        }
        if (job.method == "probe") {
          auto p = response.GetNamedObject(L"probe");
          Map value{
              {Value("reachable"), Value(p.GetNamedBoolean(L"reachable"))}};
          if (p.HasKey(L"latencyMs"))
            value.emplace(
                Value("latencyMs"),
                Value(static_cast<int64_t>(p.GetNamedNumber(L"latencyMs"))));
          if (p.HasKey(L"errorCode"))
            value.emplace(
                Value("errorCode"),
                Value(winrt::to_string(p.GetNamedString(L"errorCode"))));
          completion.value = Value(value);
        }
      } else {
        Fail("native_method_unsupported");
      }
    } catch (const std::runtime_error& e) {
      completion.error = e.what();
      if (job.method == "getStatus") {
        bool cleanup = false;
        try { cleanup = system_proxy.HasLease(); }
        catch (...) { cleanup = true; }
        if (cleanup && !status_seen) last_mode = "proxy";
        if (auto* status = std::get_if<Map>(&completion.status)) {
          (*status)[Value("phase")] = Value("error");
          (*status)[Value("processCrashProtection")] = Value(false);
          (*status)[Value("errorCode")] = Value(e.what());
          (*status)[Value("cleanupRequired")] = Value(cleanup);
        } else {
          completion.status = Unavailable(e.what(), last_mode, proxy_supported, cleanup);
        }
        completion.value = completion.status;
        completion.error.clear();
      }
    } catch (...) {
      completion.error = "native_request_failed";
      if (job.method == "getStatus") {
        bool cleanup = false;
        try { cleanup = system_proxy.HasLease(); }
        catch (...) { cleanup = true; }
        if (cleanup && !status_seen) last_mode = "proxy";
        completion.status = Unavailable("native_request_failed", last_mode,
                                         proxy_supported, cleanup);
        completion.value = completion.status;
        completion.error.clear();
      }
    }
    if (completion.error.rfind("proxy_", 0) == 0) {
      if (auto* status = std::get_if<Map>(&completion.status)) {
        (*status)[Value("phase")] = Value("error");
        (*status)[Value("processCrashProtection")] = Value(false);
        (*status)[Value("errorCode")] = Value(completion.error);
        bool cleanup = true;
        try { cleanup = system_proxy.HasLease(); } catch (...) {}
        (*status)[Value("cleanupRequired")] = Value(cleanup);
      }
    }
    if (job.method == "getStatus" &&
        !std::holds_alternative<Map>(completion.traffic))
      completion.traffic_error = "statistics_unavailable";
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) break;
      completed_.push_back(std::move(completion));
    }
    PostMessageW(window_, kMessage, 0, 0);
  }
  winrt::uninit_apartment();
}
void VpnBridge::Drain() {
  std::deque<Completion> ready;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    ready.swap(completed_);
  }
  for (auto& completion : ready) {
    if (state_sink_ && std::holds_alternative<Map>(completion.status))
      state_sink_->Success(completion.status);
    if (stats_sink_) {
      if (std::holds_alternative<Map>(completion.traffic))
        stats_sink_->Success(completion.traffic);
      else if (!completion.traffic_error.empty())
        stats_sink_->Error(completion.traffic_error,
                           "Traffic counters are unavailable");
    }
    if (completion.result) {
      if (completion.error.empty())
        completion.result->Success(completion.value);
      else
        completion.result->Error(completion.error,
                                 "Native request could not be applied");
    }
  }
}
