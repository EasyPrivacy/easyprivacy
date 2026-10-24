#ifndef RUNNER_VPN_TRAY_H_
#define RUNNER_VPN_TRAY_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <optional>
#include <string>

class VPNTray {
 public:
  VPNTray(HWND window, flutter::BinaryMessenger* messenger);
  ~VPNTray();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void Update();
  void Open();
  void Menu();
  HWND window_;
  UINT taskbar_created_;
  bool visible_ = false;
  bool added_ = false;
  bool action_enabled_ = false;
  bool quitting_ = false;
  std::wstring status_ = L"VPN disconnected";
  std::string action_ = "connect";
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
