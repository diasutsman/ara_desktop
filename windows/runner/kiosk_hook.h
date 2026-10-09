#ifndef RUNNER_KIOSK_HOOK_H_
#define RUNNER_KIOSK_HOOK_H_

#include <flutter/binary_messenger.h>

// Registers the MethodChannel 'ara_desktop/kiosk_hook' with the binary messenger.
void RegisterKioskHookChannel(flutter::BinaryMessenger* messenger);

// Sets whether the low-level keyboard hook blocks Alt+Tab, Windows Key, etc.
void SetKioskHookEnabled(bool enabled);

// Completely unhooks the Windows hook (called on window destruction).
void CleanupKioskHook();

// Returns true if the kiosk lockdown is actively engaged.
bool IsKioskWindowLocked();

#endif  // RUNNER_KIOSK_HOOK_H_
