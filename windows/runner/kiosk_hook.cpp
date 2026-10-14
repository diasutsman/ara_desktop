#include "kiosk_hook.h"

#include <windows.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <vsstyle.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <iostream>

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "uxtheme.lib")

namespace {

// Undocumented Windows MenuBar Drawing (UAH - User32 Aero Hook)
#ifndef WM_UAHDRAWMENU
#define WM_UAHDESTROYWINDOW    0x0090
#define WM_UAHDRAWMENU         0x0091
#define WM_UAHDRAWMENUITEM     0x0092
#define WM_UAHINITMENU         0x0093
#define WM_UAHMEASUREMENUITEM  0x0094
#define WM_UAHNCPAINTMENUPOPUP 0x0095

typedef union tagUAHMENUITEMMETRICS {
  struct {
    DWORD cx;
    DWORD cy;
  } rgsizeBar[2];
  struct {
    DWORD cx;
    DWORD cy;
  } rgsizePopup[4];
} UAHMENUITEMMETRICS;

typedef struct tagUAHMENUPOPUPMETRICS {
  DWORD rgcx[4];
  DWORD fUpdateMaxWidths : 2;
} UAHMENUPOPUPMETRICS;

typedef struct tagUAHMENU {
  HMENU hmenu;
  HDC hdc;
  DWORD dwFlags;
} UAHMENU;

typedef struct tagUAHMENUITEM {
  int iPosition;
  UAHMENUITEMMETRICS umim;
  UAHMENUPOPUPMETRICS umpm;
} UAHMENUITEM;

typedef struct UAHDRAWMENUITEM {
  DRAWITEMSTRUCT dis;
  UAHMENU um;
  UAHMENUITEM umi;
} UAHDRAWMENUITEM;

typedef struct tagUAHMEASUREMENUITEM {
  MEASUREITEMSTRUCT mis;
  UAHMENU um;
  UAHMENUITEM umi;
} UAHMEASUREMENUITEM;
#ifndef MENU_BARITEM
#define MENU_BARITEM 8
#endif
#ifndef MBI_NORMAL
#define MBI_NORMAL 1
#define MBI_HOT 2
#define MBI_PUSHED 3
#define MBI_DISABLED 4
#endif
#endif

// The window titlebar color sampled from Windows 10/11 dark titlebar (#2B2B2B)
constexpr COLORREF kWindowBarColor = RGB(43, 43, 43);
constexpr COLORREF kItemHoverColor = RGB(65, 65, 65);
constexpr COLORREF kItemHoverBorder = RGB(80, 80, 80);
constexpr COLORREF kItemPressedColor = RGB(80, 80, 80);
constexpr COLORREF kItemPressedBorder = RGB(95, 95, 95);
constexpr COLORREF kTextColor = RGB(245, 245, 245);
constexpr COLORREF kDisabledTextColor = RGB(130, 130, 130);

static HTHEME s_menuTheme = nullptr;

enum PreferredAppMode {
  Default,
  AllowDark,
  ForceDark,
  ForceLight,
  Max
};

using fnSetPreferredAppMode = PreferredAppMode (WINAPI *)(PreferredAppMode appMode);
using fnAllowDarkModeForWindow = BOOL (WINAPI *)(HWND hWnd, BOOL allow);
using fnFlushMenuThemes = void (WINAPI *)();

void InitializeWindowDarkMode(HWND hwnd) {
  if (hwnd == nullptr || !::IsWindow(hwnd)) return;

  static bool s_isInitializingTheme = false;
  if (s_isInitializingTheme) return;
  s_isInitializingTheme = true;

  // 1. DWM Immersive Dark Mode for window title bar (attribute 20)
  BOOL darkMode = TRUE;
  ::DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &darkMode, sizeof(darkMode));

  // 2. Set title bar caption color and text color explicitly for Windows 11 (build 22000+)
  COLORREF captionColor = kWindowBarColor;
  ::DwmSetWindowAttribute(hwnd, 35 /* DWMWA_CAPTION_COLOR */, &captionColor, sizeof(captionColor));
  COLORREF textColor = RGB(255, 255, 255);
  ::DwmSetWindowAttribute(hwnd, 36 /* DWMWA_TEXT_COLOR */, &textColor, sizeof(textColor));

  // 3. UxTheme dark mode for menus (turns popup menus into sleek dark mode)
  HMODULE hUxtheme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (hUxtheme != nullptr) {
    auto pfnSetPreferredAppMode = reinterpret_cast<fnSetPreferredAppMode>(
        GetProcAddress(hUxtheme, MAKEINTRESOURCEA(135)));
    if (pfnSetPreferredAppMode != nullptr) {
      pfnSetPreferredAppMode(ForceDark);
    } else {
      using fnAllowDarkModeForApp = BOOL (WINAPI *)(BOOL allow);
      auto pfnAllowDarkModeForApp = reinterpret_cast<fnAllowDarkModeForApp>(
          GetProcAddress(hUxtheme, MAKEINTRESOURCEA(135)));
      if (pfnAllowDarkModeForApp != nullptr) {
        pfnAllowDarkModeForApp(TRUE);
      }
    }

    auto pfnAllowDarkModeForWindow = reinterpret_cast<fnAllowDarkModeForWindow>(
        GetProcAddress(hUxtheme, MAKEINTRESOURCEA(133)));
    if (pfnAllowDarkModeForWindow != nullptr) {
      pfnAllowDarkModeForWindow(hwnd, TRUE);
    }

    auto pfnFlushMenuThemes = reinterpret_cast<fnFlushMenuThemes>(
        GetProcAddress(hUxtheme, MAKEINTRESOURCEA(136)));
    if (pfnFlushMenuThemes != nullptr) {
      pfnFlushMenuThemes();
    }

    // NOTE: DO NOT call SetWindowTheme(hwnd, L"DarkMode_Explorer", nullptr) on a window
    // with a native HMENU! DarkMode_Explorer suppresses/hides classic Win32 menu bars!
  }

  s_isInitializingTheme = false;
}

void UAHDrawMenuNCBottomLine(HWND hwnd) {
  MENUBARINFO mbi = { sizeof(mbi) };
  if (!GetMenuBarInfo(hwnd, OBJID_MENU, 0, &mbi)) {
    return;
  }

  RECT rcClient = { 0 };
  GetClientRect(hwnd, &rcClient);
  MapWindowPoints(hwnd, nullptr, reinterpret_cast<POINT*>(&rcClient), 2);

  RECT rcWindow = { 0 };
  GetWindowRect(hwnd, &rcWindow);

  OffsetRect(&rcClient, -rcWindow.left, -rcWindow.top);

  RECT rcLine = rcClient;
  rcLine.bottom = rcLine.top;
  rcLine.top--;

  if (rcLine.bottom > rcLine.top && rcLine.top >= 0) {
    HDC hdc = GetWindowDC(hwnd);
    if (hdc != nullptr) {
      static HBRUSH s_barBrush = CreateSolidBrush(kWindowBarColor);
      FillRect(hdc, &rcLine, s_barBrush);
      ReleaseDC(hwnd, hdc);
    }
  }
}

HHOOK g_keyboardHook = nullptr;
HWND g_mainWindowHandle = nullptr;
bool g_isAltTabBlocked = false;
bool g_isWindowControlsLocked = false;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_kioskChannel;

// Low-level keyboard hook callback to intercept system shortcuts
LRESULT CALLBACK LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam) {
  if (nCode == HC_ACTION && g_isAltTabBlocked) {
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
  g_isAltTabBlocked = enabled;

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

void SetWindowControlsLocked(bool locked) {
  g_isWindowControlsLocked = locked;
  std::cout << "[KioskHook] Win32 Window Controls Lock set to: " << (locked ? "LOCKED" : "UNLOCKED") << std::endl;

  if (g_mainWindowHandle != nullptr && ::IsWindow(g_mainWindowHandle)) {
    LONG_PTR style = ::GetWindowLongPtr(g_mainWindowHandle, GWL_STYLE);
    // Ensure WS_SYSMENU is always present so the native menu bar remains active and visible!
    style |= WS_SYSMENU;

    if (locked) {
      // Remove minimize and maximize buttons natively from OS title bar.
      style &= ~WS_MINIMIZEBOX;
      style &= ~WS_MAXIMIZEBOX;
    } else {
      style |= (WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
    }
    ::SetWindowLongPtr(g_mainWindowHandle, GWL_STYLE, style);

    // Disable the System Menu's Close item natively so 'X' is grayed out/disabled
    HMENU hSysMenu = ::GetSystemMenu(g_mainWindowHandle, FALSE);
    if (hSysMenu != nullptr) {
      if (locked) {
        ::EnableMenuItem(hSysMenu, SC_CLOSE, MF_BYCOMMAND | MF_DISABLED | MF_GRAYED);
      } else {
        ::EnableMenuItem(hSysMenu, SC_CLOSE, MF_BYCOMMAND | MF_ENABLED);
      }
    }

    // Ensure native HMENU is attached if it was ever missing
    if (::GetMenu(g_mainWindowHandle) == nullptr) {
      AttachNativeMenuBar(g_mainWindowHandle);
    }

    ::SetWindowPos(g_mainWindowHandle, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);

    InitializeWindowDarkMode(g_mainWindowHandle);
    ::DrawMenuBar(g_mainWindowHandle);
  }
}

void AttachNativeMenuBar(HWND hwnd) {
  if (hwnd == nullptr || !::IsWindow(hwnd)) return;

  HMENU hExistingMenu = ::GetMenu(hwnd);
  if (hExistingMenu != nullptr) return; // Already attached

  HMENU hMenuBar = ::CreateMenu();

  ::AppendMenuW(hMenuBar, MF_STRING, ID_MENU_WORD, L"Word");
  ::AppendMenuW(hMenuBar, MF_STRING, ID_MENU_EXCEL, L"Excel");
  ::AppendMenuW(hMenuBar, MF_STRING, ID_MENU_POWERPOINT, L"PowerPoint");

  // Apply dark background brush to menu
  static HBRUSH s_menuBrush = CreateSolidBrush(kWindowBarColor);
  MENUINFO mi = { sizeof(MENUINFO) };
  mi.cbSize = sizeof(MENUINFO);
  mi.fMask = MIM_BACKGROUND | MIM_APPLYTOSUBMENUS;
  mi.hbrBack = s_menuBrush;
  ::SetMenuInfo(hMenuBar, &mi);

  ::SetMenu(hwnd, hMenuBar);
  ::DrawMenuBar(hwnd);

  InitializeWindowDarkMode(hwnd);
  std::cout << "[KioskHook] Native Win32 Menu Bar attached (Word, Excel, PowerPoint) to HWND: " << hwnd << std::endl;
}

bool HandleNativeMenuBarMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result) {
  if (hwnd == nullptr || ::GetMenu(hwnd) == nullptr) {
    return false;
  }

  switch (message) {
    case WM_UAHDRAWMENU: {
      UAHMENU* pUDM = reinterpret_cast<UAHMENU*>(lparam);
      if (pUDM != nullptr) {
        RECT rcWindow = { 0 };
        GetWindowRect(hwnd, &rcWindow);

        MENUBARINFO mbi = { sizeof(mbi) };
        GetMenuBarInfo(hwnd, OBJID_MENU, 0, &mbi);

        RECT rc = mbi.rcBar;
        OffsetRect(&rc, -rcWindow.left, -rcWindow.top);

        // Bentangkan rc ke seluruh lebar jendela agar tidak ada strip putih default Windows
        rc.left = 0;
        rc.right = rcWindow.right - rcWindow.left;

        static HBRUSH s_barBrush = CreateSolidBrush(kWindowBarColor);
        FillRect(pUDM->hdc, &rc, s_barBrush);
      }
      *result = 0;
      return true;
    }

    case WM_UAHDRAWMENUITEM: {
      UAHDRAWMENUITEM* pUDMI = reinterpret_cast<UAHDRAWMENUITEM*>(lparam);
      if (pUDMI != nullptr) {
        static HBRUSH s_itemBg = CreateSolidBrush(kWindowBarColor);
        static HBRUSH s_itemHot = CreateSolidBrush(kItemHoverColor);
        static HBRUSH s_itemSelected = CreateSolidBrush(kItemPressedColor);
        static HBRUSH s_borderHot = CreateSolidBrush(kItemHoverBorder);
        static HBRUSH s_borderSelected = CreateSolidBrush(kItemPressedBorder);

        HBRUSH hbrBg = s_itemBg;
        HBRUSH hbrBorder = s_itemBg;
        int iTextStateID = MBI_NORMAL;

        if (pUDMI->dis.itemState & ODS_SELECTED) {
          hbrBg = s_itemSelected;
          hbrBorder = s_borderSelected;
          iTextStateID = MBI_PUSHED;
        } else if (pUDMI->dis.itemState & ODS_HOTLIGHT) {
          hbrBg = s_itemHot;
          hbrBorder = s_borderHot;
          iTextStateID = MBI_HOT;
        } else if ((pUDMI->dis.itemState & ODS_GRAYED) || (pUDMI->dis.itemState & ODS_DISABLED)) {
          iTextStateID = MBI_DISABLED;
        }

        FillRect(pUDMI->um.hdc, &pUDMI->dis.rcItem, hbrBg);
        if ((pUDMI->dis.itemState & ODS_HOTLIGHT) || (pUDMI->dis.itemState & ODS_SELECTED)) {
          FrameRect(pUDMI->um.hdc, &pUDMI->dis.rcItem, hbrBorder);
        }

        wchar_t menuString[256] = { 0 };
        int len = ::GetMenuStringW(pUDMI->um.hmenu, pUDMI->umi.iPosition, menuString, 255, MF_BYPOSITION);
        if (len <= 0) {
          MENUITEMINFO mii = { sizeof(mii), MIIM_STRING };
          mii.dwTypeData = menuString;
          mii.cch = 255;
          if (GetMenuItemInfoW(pUDMI->um.hmenu, pUDMI->umi.iPosition, TRUE, &mii) && mii.cch > 0) {
            len = static_cast<int>(mii.cch);
          } else {
            wcscpy_s(menuString, L"Item");
            len = static_cast<int>(wcslen(menuString));
          }
        }

        DWORD dwFlags = DT_CENTER | DT_SINGLELINE | DT_VCENTER;
        if (pUDMI->dis.itemState & ODS_NOACCEL) {
          dwFlags |= DT_HIDEPREFIX;
        }

        if (!s_menuTheme) {
          s_menuTheme = OpenThemeData(hwnd, L"Menu");
        }

        COLORREF textColor = (iTextStateID == MBI_DISABLED) ? kDisabledTextColor : kTextColor;
        DTTOPTS opts = { sizeof(opts) };
        opts.dwFlags = DTT_TEXTCOLOR;
        opts.crText = textColor;

        if (s_menuTheme != nullptr) {
          DrawThemeTextEx(s_menuTheme, pUDMI->um.hdc, MENU_BARITEM, iTextStateID,
                          menuString, len, dwFlags, &pUDMI->dis.rcItem, &opts);
        } else {
          int oldBkMode = SetBkMode(pUDMI->um.hdc, TRANSPARENT);
          COLORREF oldTextColor = SetTextColor(pUDMI->um.hdc, textColor);
          DrawTextW(pUDMI->um.hdc, menuString, len, &pUDMI->dis.rcItem, dwFlags);
          SetTextColor(pUDMI->um.hdc, oldTextColor);
          SetBkMode(pUDMI->um.hdc, oldBkMode);
        }
      }
      *result = 0;
      return true;
    }

    case WM_UAHMEASUREMENUITEM: {
      *result = DefWindowProc(hwnd, message, wparam, lparam);
      return true;
    }

    case WM_NCPAINT:
    case WM_NCACTIVATE: {
      *result = DefWindowProc(hwnd, message, wparam, lparam);
      UAHDrawMenuNCBottomLine(hwnd);
      return true;
    }

    case WM_THEMECHANGED: {
      static bool s_inThemeChanged = false;
      if (!s_inThemeChanged) {
        s_inThemeChanged = true;
        if (s_menuTheme != nullptr) {
          CloseThemeData(s_menuTheme);
          s_menuTheme = nullptr;
        }
        InitializeWindowDarkMode(hwnd);
        DrawMenuBar(hwnd);
        s_inThemeChanged = false;
      }
      return false;
    }

    default:
      return false;
  }
}

void NotifyOfficeAppLaunched(const std::string& appName) {
  if (g_kioskChannel != nullptr) {
    g_kioskChannel->InvokeMethod(
        "onOfficeLaunched",
        std::make_unique<flutter::EncodableValue>(appName));
  }
}

void CleanupKioskHook() {
  if (s_menuTheme != nullptr) {
    CloseThemeData(s_menuTheme);
    s_menuTheme = nullptr;
  }
  SetKioskHookEnabled(false);
  SetWindowControlsLocked(false);
  g_kioskChannel = nullptr;
}

bool IsWindowControlsLocked() {
  return g_isWindowControlsLocked;
}

void ForceWindowToForeground(HWND hwnd) {
  if (hwnd == nullptr) {
    hwnd = g_mainWindowHandle;
  }
  if (hwnd == nullptr || !::IsWindow(hwnd)) return;

  HWND hForegroundWnd = ::GetForegroundWindow();
  if (hForegroundWnd == hwnd) return;

  DWORD dwCurID = ::GetCurrentThreadId();
  DWORD dwTargetID = hForegroundWnd ? ::GetWindowThreadProcessId(hForegroundWnd, nullptr) : 0;

  // 1. Attach input queues to bypass Windows ASFW Foreground Lockout
  if (dwTargetID != 0 && dwCurID != dwTargetID) {
    ::AttachThreadInput(dwCurID, dwTargetID, TRUE);
  }

  // 2. Bring window to topmost briefly then back to normal to pierce Z-order
  ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  ::SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);

  // 3. Show, activate, and focus window
  ::ShowWindow(hwnd, SW_SHOW);
  ::BringWindowToTop(hwnd);
  ::SetForegroundWindow(hwnd);
  ::SetActiveWindow(hwnd);
  ::SetFocus(hwnd);

  // 4. Detach thread input
  if (dwTargetID != 0 && dwCurID != dwTargetID) {
    ::AttachThreadInput(dwCurID, dwTargetID, FALSE);
  }
  std::cout << "[KioskHook] ForceWindowToForeground executed successfully for HWND: " << hwnd << std::endl;
}

void RegisterKioskHookChannel(flutter::BinaryMessenger* messenger, HWND windowHandle) {
  if (messenger == nullptr) return;

  if (windowHandle != nullptr) {
    g_mainWindowHandle = windowHandle;
    std::cout << "[KioskHook] Main window HWND registered: " << windowHandle << std::endl;
    AttachNativeMenuBar(windowHandle);
  }

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
        } else if (method == "setWindowLock") {
          bool lock = false;
          const auto* args = call.arguments();
          if (args != nullptr) {
            if (std::holds_alternative<bool>(*args)) {
              lock = std::get<bool>(*args);
            } else if (std::holds_alternative<flutter::EncodableMap>(*args)) {
              const auto& map = std::get<flutter::EncodableMap>(*args);
              auto it = map.find(flutter::EncodableValue("locked"));
              if (it != map.end() && std::holds_alternative<bool>(it->second)) {
                lock = std::get<bool>(it->second);
              }
            }
          }
          SetWindowControlsLocked(lock);
          result->Success(flutter::EncodableValue(true));
        } else if (method == "forceForeground") {
          ForceWindowToForeground(g_mainWindowHandle);
          result->Success(flutter::EncodableValue(true));
        } else if (method == "isHookActive") {
          result->Success(flutter::EncodableValue(g_isAltTabBlocked));
        } else if (method == "isWindowLocked") {
          result->Success(flutter::EncodableValue(g_isWindowControlsLocked));
        } else if (method == "cleanup") {
          CleanupKioskHook();
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
}
