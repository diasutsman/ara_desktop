#include "flutter_window.h"

#include <optional>
#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"
#include "kiosk_hook.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterKioskHookChannel(flutter_controller_->engine()->messenger(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  CleanupKioskHook();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // If Window Controls Lock is active, block toolbar double-click, minimize, restore, resize, drag, and close!
  if (IsWindowControlsLocked()) {
    switch (message) {
      // 1. Block double-clicking anywhere on the top toolbar / title bar / caption / borders
      case WM_NCLBUTTONDBLCLK:
        return 0;

      // 2. Block system commands: Minimize, Restore (unmaximize), Maximize, Move/Drag, Resize, Close, System Menu
      case WM_SYSCOMMAND: {
        WPARAM sysCmd = (wparam & 0xFFF0);
        if (sysCmd == SC_MINIMIZE ||
            sysCmd == SC_RESTORE ||
            sysCmd == SC_MAXIMIZE ||
            sysCmd == SC_MOVE ||
            sysCmd == SC_SIZE ||
            sysCmd == SC_CLOSE ||
            sysCmd == SC_KEYMENU) {
          return 0; // Deny system command completely
        }
        break;
      }

      // 3. Block clicking on caption buttons (minimize, maximize, close) or dragging the caption
      case WM_NCLBUTTONDOWN:
        if (wparam == HTCAPTION ||
            wparam == HTMINBUTTON ||
            wparam == HTMAXBUTTON ||
            wparam == HTCLOSE) {
          return 0;
        }
        break;

      // 4. Block right-click context menu on title bar
      case WM_NCRBUTTONDOWN:
      case WM_NCRBUTTONUP:
        if (wparam == HTCAPTION) {
          return 0;
        }
        break;
    }
  }

  // Handle Native Win32 Menu commands (WM_COMMAND)
  if (message == WM_COMMAND) {
    UINT id = LOWORD(wparam);
    if (id == ID_MENU_WORD) {
      ::ShellExecuteW(nullptr, L"open", L"winword.exe", nullptr, nullptr, SW_SHOWNORMAL);
      NotifyOfficeAppLaunched("winword");
      return 0;
    } else if (id == ID_MENU_EXCEL) {
      ::ShellExecuteW(nullptr, L"open", L"excel.exe", nullptr, nullptr, SW_SHOWNORMAL);
      NotifyOfficeAppLaunched("excel");
      return 0;
    } else if (id == ID_MENU_POWERPOINT) {
      ::ShellExecuteW(nullptr, L"open", L"powerpnt.exe", nullptr, nullptr, SW_SHOWNORMAL);
      NotifyOfficeAppLaunched("powerpnt");
      return 0;
    }
  }

  // Handle Native Win32 MenuBar Dark Theme Rendering
  LRESULT menuResult = 0;
  if (HandleNativeMenuBarMessage(hwnd, message, wparam, lparam, &menuResult)) {
    return menuResult;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
