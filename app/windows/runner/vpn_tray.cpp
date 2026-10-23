#include "vpn_tray.h"

#include <shellapi.h>
#include <flutter/standard_method_codec.h>
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 41;
constexpr UINT kOpenMessage = WM_APP + 42;
constexpr UINT kIconId = 1;
constexpr UINT kOpen = 1, kAction = 2, kQuit = 3;

std::wstring Wide(const std::string& text) {
  if (text.empty()) return L"";
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                      static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      result.data(), size);
  return result;
}

template <typename T>
T Read(const flutter::EncodableMap& map, const char* key, T fallback) {
  const auto value = map.find(flutter::EncodableValue(key));
  if (value == map.end()) return fallback;
  const auto* typed = std::get_if<T>(&value->second);
  return typed ? *typed : fallback;
}
}  // namespace

VPNTray::VPNTray(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window), taskbar_created_(RegisterWindowMessage(L"TaskbarCreated")) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "org.easyprivacy/presence",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "update") {
      const auto* args = call.arguments()
          ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      if (!args) {
        result->Error("invalid_state", "Expected VPN indicator state.");
        return;
      }
      visible_ = Read(*args, "visible", false);
      status_ = Wide(Read(*args, "status", std::string("VPN disconnected")));
      action_ = Read(*args, "action", std::string("connect"));
      action_enabled_ = Read(*args, "actionEnabled", false);
      Update();
      if (visible_ && !added_) {
        result->Error("tray_unavailable", "Windows could not show the VPN indicator.");
      } else {
        result->Success(flutter::EncodableValue(true));
      }
    } else if (call.method_name() == "pendingAction") {
      result->Success();
    } else if (call.method_name() == "requestPermission") {
      result->Success(flutter::EncodableValue(true));
    } else if (call.method_name() == "openSettings") {
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

VPNTray::~VPNTray() {
  channel_->SetMethodCallHandler(nullptr);
  NOTIFYICONDATA data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  Shell_NotifyIcon(NIM_DELETE, &data);
}

void VPNTray::Update() {
  NOTIFYICONDATA data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  if (!visible_) {
    if (added_) Shell_NotifyIcon(NIM_DELETE, &data);
    added_ = false;
    // Do not leave a hidden process with neither window nor tray access.
    if (!IsWindowVisible(window_)) Open();
    return;
  }
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  const auto tooltip = L"EasyPrivacy - " + status_;
  wcsncpy_s(data.szTip, tooltip.c_str(), _TRUNCATE);
  if (Shell_NotifyIcon(added_ ? NIM_MODIFY : NIM_ADD, &data)) {
    added_ = true;
    data.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIcon(NIM_SETVERSION, &data);
  } else {
    added_ = false;
    if (!IsWindowVisible(window_)) Open();
  }
}

void VPNTray::Open() {
  ShowWindow(window_, SW_RESTORE);
  SetForegroundWindow(window_);
}

void VPNTray::Menu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenu(menu, MF_STRING | MF_DISABLED, 0, status_.c_str());
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kOpen, L"Open EasyPrivacy");
  AppendMenu(menu, MF_STRING | (action_enabled_ ? MF_ENABLED : MF_GRAYED),
             kAction, action_ == "disconnect" ? L"Disconnect VPN" : L"Connect VPN");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kQuit,
             action_ == "disconnect" ? L"Quit EasyPrivacy (VPN stays active)" : L"Quit EasyPrivacy");
  POINT point{};
  GetCursorPos(&point);
  SetForegroundWindow(window_);
  const auto chosen = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                    point.x, point.y, 0, window_, nullptr);
  DestroyMenu(menu);
  PostMessage(window_, WM_NULL, 0, 0);
  if (chosen == kOpen) Open();
  if (chosen == kAction && action_enabled_) {
    action_enabled_ = false;
    // Show consent dialogs and any connection errors in the existing window.
    Open();
    channel_->InvokeMethod(action_, nullptr);
  }
  if (chosen == kQuit) {
    quitting_ = true;
    DestroyWindow(window_);
  }
}

std::optional<LRESULT> VPNTray::HandleMessage(UINT message, WPARAM, LPARAM lparam) {
  if (message == taskbar_created_) {
    added_ = false;
    Update();
    return 0;
  }
  if (message == kOpenMessage) { Open(); return 0; }
  if (message == WM_CLOSE && visible_ && added_ && !quitting_) {
    ShowWindow(window_, SW_HIDE);
    return 0;
  }
  if (message == kTrayMessage) {
    const auto event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT) Open();
    if (event == WM_CONTEXTMENU) Menu();
    return 0;
  }
  return std::nullopt;
}
