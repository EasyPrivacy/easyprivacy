#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  const bool broker = std::find(command_line_arguments.begin(),
                                command_line_arguments.end(), "--core-broker") !=
                      command_line_arguments.end();
  HANDLE single_instance = CreateMutex(
      nullptr, FALSE, broker ? L"Local\\org.easyprivacy.easyprivacy.broker"
                             : L"Local\\org.easyprivacy.easyprivacy");
  if (single_instance && GetLastError() == ERROR_ALREADY_EXISTS) {
    if (!broker) {
      HWND existing = FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"EasyPrivacy");
      if (existing) {
        ShowWindow(existing, SW_RESTORE);
        SetForegroundWindow(existing);
        PostMessage(existing, WM_APP + 42, 0, 0);
      }
    }
    CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, broker);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(broker ? L"EasyPrivacy Core Broker" : L"EasyPrivacy", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance) CloseHandle(single_instance);
  return EXIT_SUCCESS;
}
