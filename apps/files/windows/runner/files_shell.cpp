#include "files_shell.h"
#include <shellapi.h>
#include <shlobj.h>
#include <flutter/standard_method_codec.h>
#include "resource.h"
namespace {
constexpr UINT kTray = WM_APP + 41, kOpen = WM_APP + 42;
std::wstring Wide(const std::string& value) {
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(count, L'\0');
  if (count) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), count);
  return result;
}
}
FilesShell::FilesShell(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window), taskbar_created_(RegisterWindowMessage(L"TaskbarCreated")) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "org.easyprivacy/files_presence", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* map = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    if (call.method_name() == "update" && map) {
      auto value = map->find(flutter::EncodableValue("active"));
      active_ = value != map->end() && std::get_if<bool>(&value->second) && std::get<bool>(value->second);
      Update();
      if (active_ && !added_) result->Error("tray_unavailable", "Windows could not show the Files tray icon.");
      else result->Success();
    } else if ((call.method_name() == "openFile" || call.method_name() == "openFolder") && map) {
      auto entry = map->find(flutter::EncodableValue("path"));
      const auto* text = entry == map->end() ? nullptr : std::get_if<std::string>(&entry->second);
      if (!text) { result->Error("invalid_path", "Choose a local file or folder."); return; }
      const auto path = Wide(*text);
      const auto attrs = GetFileAttributesW(path.c_str());
      if (attrs == INVALID_FILE_ATTRIBUTES) { result->Error("unavailable", "This item is unavailable locally."); return; }
      if (call.method_name() == "openFolder") {
        if (!(attrs & FILE_ATTRIBUTE_DIRECTORY) || reinterpret_cast<INT_PTR>(ShellExecuteW(window_, L"explore", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) <= 32) {
          result->Error("open_failed", "Could not open this folder."); return;
        }
      } else {
        if (attrs & FILE_ATTRIBUTE_DIRECTORY) { result->Error("invalid_path", "Choose a file."); return; }
        OPENASINFO info{};
        info.pcszFile = path.c_str();
        info.oaifInFlags = static_cast<OPEN_AS_INFO_FLAGS>(OAIF_EXEC | OAIF_ALLOW_REGISTRATION);
        const HRESULT status = SHOpenWithDialog(window_, &info);
        if (FAILED(status) && status != HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
          result->Error("open_failed", "Could not show the application chooser."); return;
        }
      }
      result->Success();
    } else if (call.method_name() == "requestPermission") result->Success(flutter::EncodableValue(true));
    else result->NotImplemented();
  });
}
FilesShell::~FilesShell() {
  channel_->SetMethodCallHandler(nullptr);
  NOTIFYICONDATAW data{}; data.cbSize = sizeof(data); data.hWnd = window_; data.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &data);
}
void FilesShell::Open() { ShowWindow(window_, SW_RESTORE); SetForegroundWindow(window_); }
void FilesShell::Update() {
  NOTIFYICONDATAW data{}; data.cbSize = sizeof(data); data.hWnd = window_; data.uID = 1;
  if (!active_) {
    if (added_) Shell_NotifyIconW(NIM_DELETE, &data);
    added_ = false;
    if (!IsWindowVisible(window_)) Open();
    return;
  }
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTray;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(data.szTip, L"EasyPrivacy Files - folder Sync active");
  added_ = Shell_NotifyIconW(added_ ? NIM_MODIFY : NIM_ADD, &data) != FALSE;
  if (added_) { data.uVersion = NOTIFYICON_VERSION_4; Shell_NotifyIconW(NIM_SETVERSION, &data); }
  else if (!IsWindowVisible(window_)) Open();
}
void FilesShell::Menu() {
  HMENU menu = CreatePopupMenu(); if (!menu) return;
  AppendMenuW(menu, MF_STRING, 1, L"Open EasyPrivacy Files");
  AppendMenuW(menu, MF_STRING, 2, L"Quit Files and stop syncing");
  POINT point{}; GetCursorPos(&point); SetForegroundWindow(window_);
  const auto choice = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, window_, nullptr);
  DestroyMenu(menu); PostMessage(window_, WM_NULL, 0, 0);
  if (choice == 1) Open();
  if (choice == 2) {
    quitting_ = true;
    // Windows' owned job also terminates the bundled engine on process exit.
    DestroyWindow(window_);
  }
}
std::optional<LRESULT> FilesShell::HandleMessage(UINT message, WPARAM, LPARAM lparam) {
  if (message == taskbar_created_) { added_ = false; Update(); return 0; }
  if (message == kOpen) { Open(); return 0; }
  if (message == WM_CLOSE && active_ && added_ && !quitting_) { ShowWindow(window_, SW_HIDE); return 0; }
  if (message == kTray) {
    const auto event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT) Open();
    if (event == WM_CONTEXTMENU) Menu();
    return 0;
  }
  return std::nullopt;
}
