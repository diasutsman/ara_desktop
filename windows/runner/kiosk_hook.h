#ifndef RUNNER_KIOSK_HOOK_H_
#define RUNNER_KIOSK_HOOK_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <string>

// Registers the MethodChannel 'ara_desktop/kiosk_hook' with the binary messenger and main window handle.
void RegisterKioskHookChannel(flutter::BinaryMessenger* messenger, HWND windowHandle = nullptr);

// Forces the specified window (or main window) to the foreground, bypassing Windows ASFW lockout.
void ForceWindowToForeground(HWND hwnd = nullptr);

// Sets whether the low-level keyboard hook blocks Alt+Tab, Windows Key, etc.
void SetKioskHookEnabled(bool enabled);

// Sets whether the native window controls (minimize, restore, close, double-click toolbar) are locked.
void SetWindowControlsLocked(bool locked);

// Returns true if the native window controls are currently locked.
bool IsWindowControlsLocked();

// Completely unhooks the Windows hook (called on window destruction).
void CleanupKioskHook();

// Menu command IDs for native Win32 Menu
constexpr UINT ID_MENU_WORD = 1001;
constexpr UINT ID_MENU_EXCEL = 1002;
constexpr UINT ID_MENU_POWERPOINT = 1003;

// Attaches the classic Win32 native MenuStrip/MenuBar (HMENU) to the main window
void AttachNativeMenuBar(HWND hwnd);

// Intercepts and renders the native Win32 MenuBar in dark mode matching the window title bar
bool HandleNativeMenuBarMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result);

// Notifies Dart via MethodChannel that an Office app was triggered
void NotifyOfficeAppLaunched(const std::string& appName);

#endif  // RUNNER_KIOSK_HOOK_H_
