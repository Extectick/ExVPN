// SPDX-License-Identifier: Apache-2.0
#ifndef EXVPN_SYSTEM_PROXY_H_
#define EXVPN_SYSTEM_PROXY_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

struct ProxySettings {
  uint32_t flags = 0;
  std::wstring server;
  std::wstring bypass;
  std::wstring pac;
  bool operator==(const ProxySettings&) const = default;
};

struct ProxyLease {
  ProxySettings original;
  std::wstring current_server;
  std::wstring previous_server;
};

class ProxySettingsBackend {
 public:
  virtual ~ProxySettingsBackend() = default;
  virtual ProxySettings Read() = 0;
  virtual void Apply(const ProxySettings& settings) = 0;
  virtual std::optional<ProxyLease> Load() = 0;
  virtual void Save(const std::optional<ProxyLease>& lease) = 0;
};

// The backend is injected so failure/recovery checks never alter host settings.
class SystemProxy {
 public:
  explicit SystemProxy(std::unique_ptr<ProxySettingsBackend> backend);
  void Enable(uint16_t port, bool explicit_request = true);
  void Restore();
  bool HasLease();
  static ProxySettings OwnedSettings(const std::wstring& server);
  static std::wstring Server(uint16_t port);

 private:
  static bool Owns(const ProxyLease& lease, const ProxySettings& settings);
  std::unique_ptr<ProxySettingsBackend> backend_;
};

std::unique_ptr<ProxySettingsBackend> CreateWindowsProxyBackend();

#endif
