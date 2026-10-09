#include "kiosk_hook.h"

#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <iostream>

namespace {

HHOOK g_keyboardHook = nullptr;
bool g_isKioskHookActive = false;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_kioskChannel;

// Low-level keyboard hook callback to intercept system shortcuts
LRESULT CALLBACK LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam) {
  if (nCode == HC_ACTION && g_isKioskHookActive) {
    KBDLLHOOKSTRUCT* pKey = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
    bool isAltDown = (pKey->flags & LLKHF_ALTDOWN) != 0;

    // 1. Block Alt + Tab (Task Switcher)
    if (pKey->vkCode == VK_TAB && isAltDown) {
      return 1;
    }

    // 2. Block Alt + Esc (Direct Window Switching)
    if (pKey->vkCode == VK_ESCAPE && isAltDown) {
      return 1;
    }

    // 3. Block Windows Key (Left Win and Right Win - Start Menu & shortcuts)
    if (pKey->vkCode == VK_LWIN || pKey->vkCode == VK_RWIN) {
      return 1;
    }

    // 4. Block Ctrl + Esc (Start Menu shortcut)
    if (pKey->vkCode == VK_ESCAPE) {
      if ((GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 ||
          (GetKeyState(VK_CONTROL) & 0x8000) != 0) {
        return 1;
      }
    }

    // 5. Block Alt + F4 (Close Window during strict exam)
    if (pKey->vkCode == VK_F4 && isAltDown) {
      return 1;
    }
  }

  return CallNextHookEx(g_keyboardHook, nCode, wParam, lParam);
}

}  // namespace

void SetKioskHookEnabled(bool enabled) {
  g_isKioskHookActive = enabled;

  if (enabled) {
    if (g_keyboardHook == nullptr) {
      g_keyboardHook = SetWindowsHookEx(
          WH_KEYBOARD_LL,
          LowLevelKeyboardProc,
          GetModuleHandle(nullptr),
          0);
      std::cout << "[KioskHook] Win32 WH_KEYBOARD_LL hook installed. System shortcuts locked." << std::endl;
    }
  } else {
    if (g_keyboardHook != nullptr) {
      UnhookWindowsHookEx(g_keyboardHook);
      g_keyboardHook = nullptr;
      std::cout << "[KioskHook] Win32 WH_KEYBOARD_LL hook removed. System shortcuts unlocked." << std::endl;
    }
  }
}

void CleanupKioskHook() {
  SetKioskHookEnabled(false);
  g_kioskChannel = nullptr;
}

bool IsKioskWindowLocked() {
  return g_isKioskHookActive;
}

void RegisterKioskHookChannel(flutter::BinaryMessenger* messenger) {
  if (messenger == nullptr) return;

  g_kioskChannel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger,
      "ara_desktop/kiosk_hook",
      &flutter::StandardMethodCodec::GetInstance());

  g_kioskChannel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const std::string& method = call.method_name();

        if (method == "setHook") {
          bool enable = false;
          const auto* args = call.arguments();
          if (args != nullptr) {
            if (std::holds_alternative<bool>(*args)) {
              enable = std::get<bool>(*args);
            } else if (std::holds_alternative<flutter::EncodableMap>(*args)) {
              const auto& map = std::get<flutter::EncodableMap>(*args);
              auto it = map.find(flutter::EncodableValue("enabled"));
              if (it != map.end() && std::holds_alternative<bool>(it->second)) {
                enable = std::get<bool>(it->second);
              }
            }
          }
          SetKioskHookEnabled(enable);
          result->Success(flutter::EncodableValue(true));
        } else if (method == "isHookActive") {
          result->Success(flutter::EncodableValue(g_isKioskHookActive));
        } else if (method == "cleanup") {
          CleanupKioskHook();
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
}
