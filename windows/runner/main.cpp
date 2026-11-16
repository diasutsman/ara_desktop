#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shlobj.h>
#include <uxtheme.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {
enum PreferredAppMode {
  Default,
  AllowDark,
  ForceDark,
  ForceLight,
  Max
};

using fnSetPreferredAppMode = PreferredAppMode (WINAPI *)(PreferredAppMode appMode);
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Set process-wide dark mode preference before window creation
  HMODULE hUxtheme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (hUxtheme != nullptr) {
    auto pfnSetPreferredAppMode = reinterpret_cast<fnSetPreferredAppMode>(
        GetProcAddress(hUxtheme, MAKEINTRESOURCEA(135)));
    if (pfnSetPreferredAppMode != nullptr) {
      pfnSetPreferredAppMode(ForceDark);
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // WebView2 user-data folder for the DEFAULT environment (read by the WebView2 loader).
  // Creating a custom WebViewEnvironment from Dart hung ~25s and then failed with
  // E_UNEXPECTED ("Catastrophic failure") on participant machines, delaying the first
  // page load by ~48s. The default environment starts instantly; we only redirect its
  // data folder to a writable per-user location (same folder as before => sessions kept).
  {
    wchar_t existing[8] = {0};
    if (::GetEnvironmentVariableW(L"WEBVIEW2_USER_DATA_FOLDER", existing, 8) == 0) {
      wchar_t localAppData[MAX_PATH] = {0};
      DWORD len = ::GetEnvironmentVariableW(L"LOCALAPPDATA", localAppData, MAX_PATH);
      if (len > 0 && len < MAX_PATH) {
        std::wstring folder = std::wstring(localAppData) + L"\\ARA Assessment\\WebView2_v2";
        ::SHCreateDirectoryExW(nullptr, folder.c_str(), nullptr);
        ::SetEnvironmentVariableW(L"WEBVIEW2_USER_DATA_FOLDER", folder.c_str());
      }
    }
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"ara_desktop", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
