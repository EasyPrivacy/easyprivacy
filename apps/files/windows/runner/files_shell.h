#ifndef RUNNER_FILES_SHELL_H_
#define RUNNER_FILES_SHELL_H_
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <optional>
class FilesShell {
 public:
  FilesShell(HWND window, flutter::BinaryMessenger* messenger);
  ~FilesShell();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
 private:
  void Update();
  void Open();
  void Menu();
  HWND window_;
  UINT taskbar_created_;
  bool active_ = false, added_ = false, quitting_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
