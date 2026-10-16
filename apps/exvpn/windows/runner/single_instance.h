// SPDX-License-Identifier: Apache-2.0
#ifndef EXVPN_SINGLE_INSTANCE_H_
#define EXVPN_SINGLE_INSTANCE_H_

#include <windows.h>

class SingleInstance {
 public:
  enum class Result { acquired, already_running, unavailable };
  SingleInstance() = default;
  SingleInstance(const SingleInstance&) = delete;
  SingleInstance& operator=(const SingleInstance&) = delete;
  ~SingleInstance();
  Result Acquire();
  static void ShowExistingWindow();

 private:
  HANDLE mutex_ = nullptr;
  bool owned_ = false;
};

#endif
