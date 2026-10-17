// SPDX-License-Identifier: Apache-2.0
#include "system_proxy.h"

#include <stdexcept>
#include <utility>

SystemProxy::SystemProxy(std::unique_ptr<ProxySettingsBackend> backend)
    : backend_(std::move(backend)) {}

bool SystemProxy::HasLease() { return backend_->Load().has_value(); }

std::wstring SystemProxy::Server(uint16_t port) {
  if (port == 0) throw std::runtime_error("proxy_invalid_endpoint");
  const auto endpoint = L"127.0.0.1:" + std::to_wstring(port);
  return L"http=" + endpoint + L";https=" + endpoint;
}

ProxySettings SystemProxy::OwnedSettings(const std::wstring& server) {
  // PROXY_TYPE_PROXY only: no DIRECT or automatic fallback is requested.
  return {2, server, L"", L""};
}

bool SystemProxy::Owns(const ProxyLease& lease, const ProxySettings& settings) {
  return settings == OwnedSettings(lease.current_server) ||
         (!lease.previous_server.empty() &&
          settings == OwnedSettings(lease.previous_server));
}

void SystemProxy::Enable(uint16_t port, bool explicit_request) {
  const auto server = Server(port);
  const auto target = OwnedSettings(server);
  const auto current = backend_->Read();
  auto lease = backend_->Load();
  if (lease && !Owns(*lease, current) &&
      !(explicit_request && current == lease->original))
    throw std::runtime_error("proxy_settings_changed");
  if (!lease && !explicit_request)
    throw std::runtime_error("proxy_settings_conflict");
  if (!lease && current == target)
    throw std::runtime_error("proxy_settings_conflict");
  if (lease && current == target && lease->previous_server.empty()) return;

  ProxyLease pending{lease ? lease->original : current, server,
                     lease ? lease->current_server : L""};
  // Retain both endpoints across an interrupted server switch. The original
  // user configuration is never replaced with our previous loopback endpoint.
  backend_->Save(pending);
  try {
    if (!(current == target)) backend_->Apply(target);
    if (!(backend_->Read() == target))
      throw std::runtime_error("proxy_setup_failed");
  } catch (...) {
    try {
      const auto observed = backend_->Read();
      if (Owns(pending, observed)) {
        backend_->Apply(pending.original);
        if (!(backend_->Read() == pending.original))
          throw std::runtime_error("proxy_restore_failed");
      } else if (!(observed == pending.original)) {
        throw std::runtime_error("proxy_settings_changed");
      }
      backend_->Save(std::nullopt);
    } catch (...) {
      throw std::runtime_error("proxy_restore_failed");
    }
    throw std::runtime_error("proxy_setup_failed");
  }
  pending.previous_server.clear();
  backend_->Save(pending);
}

void SystemProxy::Restore() {
  const auto lease = backend_->Load();
  if (!lease) return;
  const auto current = backend_->Read();
  // If another application/user changed the system proxy, leave it untouched.
  if (Owns(*lease, current)) {
    backend_->Apply(lease->original);
    if (!(backend_->Read() == lease->original))
      throw std::runtime_error("proxy_restore_failed");
  }
  backend_->Save(std::nullopt);
}
