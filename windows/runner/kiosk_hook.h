#ifndef RUNNER_KIOSK_HOOK_H_
#define RUNNER_KIOSK_HOOK_H_

#include <windows.h>
#include <flutter/binary_messenger.h>

// Registers the MethodChannel 'ara_desktop/kiosk_hook' with the binary messenger and main window handle.
void RegisterKioskHookChannel(flutter::BinaryMessenger* messenger, HWND windowHandle = nullptr);

// Forces the specified window (or main window) to the foreground, bypassing Windows ASFW lockout.
void ForceWindowToForeground(HWND hwnd = nullptr);

// Sets whether the low-level keyboard hook blocks Alt+Tab, Windows Key, etc.
void SetKioskHookEnabled(bool enabled);

// Sets whether the native window controls (minimize, restore, close, double-click toolbar) are locked.
void SetWindowControlsLocked(bool locked);

// Completely unhooks the Windows hook (called on window destruction).
void CleanupKioskHook();

// Returns true if the native window controls are currently locked.
bool IsWindowControlsLocked();

#endif  // RUNNER_KIOSK_HOOK_H_
