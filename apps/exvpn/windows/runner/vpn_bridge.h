// SPDX-License-Identifier: Apache-2.0
#ifndef EXVPN_VPN_BRIDGE_H_
#define EXVPN_VPN_BRIDGE_H_
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>

class VpnBridge {
 public:
  static constexpr UINT kMessage = WM_APP + 71;
  VpnBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~VpnBridge();
  void Drain();

 private:
  using Value = flutter::EncodableValue;
  using Result = flutter::MethodResult<Value>;
  struct Job {
    std::string method;
    Value arguments;
    std::unique_ptr<Result> result;
  };
  struct Completion {
    std::string error;
    Value value;
    Value status;
    Value traffic;
    std::string traffic_error;
    std::unique_ptr<Result> result;
  };
  void Work();
  void Enqueue(Job job);
  HWND window_;
  std::unique_ptr<flutter::MethodChannel<Value>> methods_;
  std::unique_ptr<flutter::EventChannel<Value>> states_;
  std::unique_ptr<flutter::EventChannel<Value>> stats_;
  std::unique_ptr<flutter::EventSink<Value>> state_sink_;
  std::unique_ptr<flutter::EventSink<Value>> stats_sink_;
  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<Job> jobs_;
  std::deque<Completion> completed_;
  bool stopping_ = false;
  std::thread worker_;
};
#endif
