// SPDX-License-Identifier: Apache-2.0
// Pure fake backend. This binary does not link WinINET, DPAPI or registry code.
#include "../system_proxy.h"
#include <functional>
#include <iostream>
#include <stdexcept>
#include <utility>

namespace {
void Check(bool ok, const char* message) {
  if (!ok) throw std::runtime_error(message);
}
void Reject(const std::function<void()>& action, const char* code) {
  try { action(); }
  catch (const std::runtime_error& error) {
    Check(std::string(error.what()) == code, "unexpected failure code");
    return;
  }
  throw std::runtime_error("expected rejection");
}
struct Fake final : ProxySettingsBackend {
  ProxySettings settings{5, L"old.example.invalid:8080", L"*.example.invalid",
                         L"https://pac.example.invalid/script.pac"};
  std::optional<ProxyLease> lease;
  int writes = 0;
  int applies = 0;
  int fail_write = 0;
  int fail_apply_after = 0;
  bool fail_all_apply = false;
  bool fail_load = false;
  ProxySettings Read() override { return settings; }
  void Apply(const ProxySettings& next) override {
    ++applies;
    if (fail_all_apply) throw std::runtime_error("proxy_setup_failed");
    settings = next;
    if (applies == fail_apply_after)
      throw std::runtime_error("proxy_setup_failed");
  }
  std::optional<ProxyLease> Load() override {
    if (fail_load) throw std::runtime_error("proxy_store_unavailable");
    return lease;
  }
  void Save(const std::optional<ProxyLease>& value) override {
    ++writes;
    if (writes == fail_write) throw std::runtime_error("proxy_store_unavailable");
    lease = value;
  }
};
struct Fixture {
  Fake* backend;
  SystemProxy proxy;
  Fixture() : Fixture(std::make_unique<Fake>()) {}
  explicit Fixture(std::unique_ptr<Fake> value)
      : backend(value.get()), proxy(std::move(value)) {}
};
}  // namespace

int main() {
  try {
    {
      Fixture f;
      const auto baseline = f.backend->settings;
      f.proxy.Enable(31001);
      Check(f.backend->lease->original == baseline, "baseline not retained");
      Check(f.backend->settings == SystemProxy::OwnedSettings(SystemProxy::Server(31001)), "wrong proxy");
      const auto writes = f.backend->writes;
      f.proxy.Enable(31001);
      Check(f.backend->writes == writes && f.backend->applies == 1, "poll rewrites settings");
      f.proxy.Enable(31002);
      Check(f.backend->lease->original == baseline, "switch lost original settings");
      f.proxy.Restore();
      Check(f.backend->settings == baseline && !f.backend->lease, "restore lost PAC/bypass/flags");
    }
    {
      Fixture f;
      const auto baseline = f.backend->settings;
      f.proxy.Enable(31001);
      auto resumed = std::make_unique<Fake>();
      resumed->settings = f.backend->settings;
      resumed->lease = f.backend->lease;
      Fixture next(std::move(resumed));
      next.proxy.Restore();
      Check(next.backend->settings == baseline && !next.backend->lease, "restart recovery failed");
    }
    {
      Fixture f;
      f.proxy.Enable(31001);
      const ProxySettings external{1, L"", L"", L""};
      f.backend->settings = external;
      Reject([&] { f.proxy.Enable(31002); }, "proxy_settings_changed");
      f.proxy.Restore();
      Check(f.backend->settings == external && !f.backend->lease, "external proxy overwritten");
    }
    {
      Fixture f;
      const auto baseline = f.backend->settings;
      f.backend->fail_apply_after = 1;
      Reject([&] { f.proxy.Enable(31001); }, "proxy_setup_failed");
      Check(f.backend->settings == baseline && !f.backend->lease, "partial API failure not recovered");
    }
    {
      Fixture f;
      const auto baseline = f.backend->settings;
      f.proxy.Enable(31001);
      f.backend->fail_all_apply = true;
      Reject([&] { f.proxy.Enable(31002); }, "proxy_restore_failed");
      Check(f.backend->lease.has_value(), "failed rollback erased recovery journal");
      f.backend->fail_all_apply = false;
      f.proxy.Restore();
      Check(f.backend->settings == baseline && !f.backend->lease, "retry did not restore original");
    }
    {
      Fixture f;
      const auto baseline = f.backend->settings;
      f.backend->fail_write = 1;
      Reject([&] { f.proxy.Enable(31001); }, "proxy_store_unavailable");
      Check(f.backend->settings == baseline && f.backend->applies == 0, "changed proxy before journal write");
    }
    {
      Fixture f;
      const auto baseline = f.backend->settings;
      f.backend->fail_write = 2;
      Reject([&] { f.proxy.Enable(31001); }, "proxy_store_unavailable");
      Check(f.backend->lease.has_value(), "commit failure lost prepared journal");
      f.proxy.Enable(31001);
      f.proxy.Restore();
      Check(f.backend->settings == baseline, "commit interruption lost baseline");
    }
    {
      Fixture f;
      const auto baseline = f.backend->settings;
      f.backend->lease = ProxyLease{baseline, SystemProxy::Server(31002), SystemProxy::Server(31001)};
      f.backend->settings = SystemProxy::OwnedSettings(SystemProxy::Server(31001));
      f.proxy.Enable(31002);
      f.proxy.Restore();
      Check(f.backend->settings == baseline, "pending two-endpoint journal not recovered");
    }
    {
      Fixture f;
      f.backend->settings = SystemProxy::OwnedSettings(SystemProxy::Server(31001));
      Reject([&] { f.proxy.Enable(31001); }, "proxy_settings_conflict");
      Check(f.backend->writes == 0, "adopted unowned proxy settings");
      Reject([&] { f.proxy.Enable(0); }, "proxy_invalid_endpoint");
    }
    {
      Fixture f;
      const auto baseline = f.backend->settings;
      f.backend->fail_load = true;
      Reject([&] { f.proxy.Enable(31001); }, "proxy_store_unavailable");
      Check(f.backend->settings == baseline && f.backend->applies == 0, "corrupt journal changed settings");
    }
    {
      Fixture f;
      const auto baseline = f.backend->settings;
      Reject([&] { f.proxy.Enable(31001, false); }, "proxy_settings_conflict");
      Check(f.backend->writes == 0 && f.backend->settings == baseline, "poll without intent captured settings");
      f.proxy.Enable(31001, true);
      f.backend->settings = baseline;
      Reject([&] { f.proxy.Enable(31001, false); }, "proxy_settings_changed");
      Check(f.backend->settings == baseline, "poll reenables manually disabled proxy");
      f.proxy.Restore();
      Reject([&] { f.proxy.Enable(31001, false); }, "proxy_settings_conflict");
      Check(f.backend->settings == baseline, "poll after failed disconnect captured settings");
    }
    std::cout << "11 system proxy policy scenarios passed (fake backend; no host changes).\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
