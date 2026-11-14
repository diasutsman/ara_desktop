#include "kiosk_hook.h"

#include <windows.h>
#include <shellapi.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <vsstyle.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <memory>
#include <iostream>
#include <string>
#include <vector>

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "uxtheme.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "shell32.lib")

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
  RECT rcWindow = { 0 };
  if (!GetWindowRect(hwnd, &rcWindow)) return;

  RECT rcClient = { 0 };
  GetClientRect(hwnd, &rcClient);
  MapWindowPoints(hwnd, nullptr, reinterpret_cast<POINT*>(&rcClient), 2);

  OffsetRect(&rcClient, -rcWindow.left, -rcWindow.top);

  RECT rcLine = rcClient;
  rcLine.left = 0;
  rcLine.right = rcWindow.right - rcWindow.left;
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

    // Menu bar is rendered directly via Flutter widgets for uniform UX across Windows, Android, and iOS
    if (::GetMenu(g_mainWindowHandle) != nullptr) {
      ::SetMenu(g_mainWindowHandle, nullptr);
    }

    ::SetWindowPos(g_mainWindowHandle, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);

    InitializeWindowDarkMode(g_mainWindowHandle);
    ::DrawMenuBar(g_mainWindowHandle);
  }
}

void AttachNativeMenuBar(HWND hwnd) {
  // Menu bar is rendered directly via Flutter widgets for uniform UX across Windows, Android, and iOS
  if (hwnd != nullptr && ::IsWindow(hwnd)) {
    ::SetMenu(hwnd, nullptr);
  }
}

bool HandleNativeMenuBarMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result) {
  if (hwnd == nullptr || ::GetMenu(hwnd) == nullptr) {
    return false;
  }

  switch (message) {
    case WM_UAHDRAWMENU: {
      UAHMENU* pUDM = reinterpret_cast<UAHMENU*>(lparam);
      if (pUDM != nullptr && pUDM->hdc != nullptr) {
        RECT rcWindow = { 0 };
        GetWindowRect(hwnd, &rcWindow);

        MENUBARINFO mbi = { sizeof(mbi) };
        RECT rc = { 0 };
        if (GetMenuBarInfo(hwnd, OBJID_MENU, 0, &mbi) && mbi.rcBar.bottom > mbi.rcBar.top) {
          rc = mbi.rcBar;
          OffsetRect(&rc, -rcWindow.left, -rcWindow.top);
        } else {
          RECT rcClient = { 0 };
          GetClientRect(hwnd, &rcClient);
          POINT ptClientTopLeft = { rcClient.left, rcClient.top };
          ClientToScreen(hwnd, &ptClientTopLeft);
          rc.top = ptClientTopLeft.y - rcWindow.top - GetSystemMetrics(SM_CYMENU);
          rc.bottom = ptClientTopLeft.y - rcWindow.top;
        }

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
        COLORREF textColor = kTextColor;

        if (pUDMI->dis.itemState & ODS_SELECTED) {
          hbrBg = s_itemSelected;
          hbrBorder = s_borderSelected;
          textColor = RGB(255, 255, 255);
        } else if (pUDMI->dis.itemState & ODS_HOTLIGHT) {
          hbrBg = s_itemHot;
          hbrBorder = s_borderHot;
          textColor = RGB(255, 255, 255);
        } else if ((pUDMI->dis.itemState & ODS_GRAYED) || (pUDMI->dis.itemState & ODS_DISABLED)) {
          textColor = kDisabledTextColor;
        }

        // Draw background to both dis.hDC and um.hdc
        if (pUDMI->dis.hDC != nullptr) {
          FillRect(pUDMI->dis.hDC, &pUDMI->dis.rcItem, hbrBg);
          if ((pUDMI->dis.itemState & ODS_HOTLIGHT) || (pUDMI->dis.itemState & ODS_SELECTED)) {
            FrameRect(pUDMI->dis.hDC, &pUDMI->dis.rcItem, hbrBorder);
          }
        }
        if (pUDMI->um.hdc != nullptr && pUDMI->um.hdc != pUDMI->dis.hDC) {
          FillRect(pUDMI->um.hdc, &pUDMI->dis.rcItem, hbrBg);
          if ((pUDMI->dis.itemState & ODS_HOTLIGHT) || (pUDMI->dis.itemState & ODS_SELECTED)) {
            FrameRect(pUDMI->um.hdc, &pUDMI->dis.rcItem, hbrBorder);
          }
        }

        // Retrieve menu item string
        wchar_t menuString[256] = { 0 };
        HMENU hMenu = (pUDMI->um.hmenu != nullptr) ? pUDMI->um.hmenu : ::GetMenu(hwnd);
        int len = 0;
        if (hMenu != nullptr) {
          len = ::GetMenuStringW(hMenu, pUDMI->umi.iPosition, menuString, 255, MF_BYPOSITION);
          if (len <= 0) {
            MENUITEMINFO mii = { sizeof(mii) };
            mii.fMask = MIIM_STRING;
            mii.dwTypeData = menuString;
            mii.cch = 255;
            if (GetMenuItemInfoW(hMenu, pUDMI->umi.iPosition, TRUE, &mii) && mii.cch > 0) {
              len = static_cast<int>(mii.cch);
            }
          }
        }

        if (len <= 0) {
          if (pUDMI->umi.iPosition == 0) wcscpy_s(menuString, L" Word ");
          else if (pUDMI->umi.iPosition == 1) wcscpy_s(menuString, L" Excel ");
          else if (pUDMI->umi.iPosition == 2) wcscpy_s(menuString, L" PowerPoint ");
          else if (pUDMI->umi.iPosition == 3) wcscpy_s(menuString, L" Refresh ");
          else wcscpy_s(menuString, L" Item ");
          len = static_cast<int>(wcslen(menuString));
        }

        DWORD dwFlags = DT_CENTER | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX;

        NONCLIENTMETRICSW ncm = { sizeof(NONCLIENTMETRICSW) };
        SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(NONCLIENTMETRICSW), &ncm, 0);
        ncm.lfMenuFont.lfWeight = FW_SEMIBOLD;
        HFONT hFont = CreateFontIndirectW(&ncm.lfMenuFont);

        auto drawTextToDc = [&](HDC dc) {
          if (dc == nullptr) return;
          HFONT oldFont = static_cast<HFONT>(SelectObject(dc, hFont));
          int oldBkMode = SetBkMode(dc, TRANSPARENT);
          COLORREF oldTextColor = SetTextColor(dc, textColor);

          DrawTextW(dc, menuString, len, &pUDMI->dis.rcItem, dwFlags);

          SetTextColor(dc, oldTextColor);
          SetBkMode(dc, oldBkMode);
          SelectObject(dc, oldFont);
        };

        if (pUDMI->dis.hDC != nullptr) {
          drawTextToDc(pUDMI->dis.hDC);
        }
        if (pUDMI->um.hdc != nullptr && pUDMI->um.hdc != pUDMI->dis.hDC) {
          drawTextToDc(pUDMI->um.hdc);
        }

        DeleteObject(hFont);
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

void NotifyRefreshRequested() {
  if (g_kioskChannel != nullptr) {
    g_kioskChannel->InvokeMethod("onRefreshRequested", nullptr);
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

namespace {

bool WriteRegAllowString(HKEY root, const std::wstring& subKey) {
  HKEY hKey = nullptr;
  DWORD disposition = 0;
  LONG res = ::RegCreateKeyExW(
      root,
      subKey.c_str(),
      0,
      nullptr,
      REG_OPTION_NON_VOLATILE,
      KEY_READ | KEY_WRITE,
      nullptr,
      &hKey,
      &disposition);
  if (res != ERROR_SUCCESS || hKey == nullptr) {
    return false;
  }
  const wchar_t kAllow[] = L"Allow";
  LONG setRes = ::RegSetValueExW(
      hKey,
      L"Value",
      0,
      REG_SZ,
      reinterpret_cast<const BYTE*>(kAllow),
      static_cast<DWORD>(sizeof(kAllow)));
  ::RegCloseKey(hKey);
  return setRes == ERROR_SUCCESS;
}

int ForceAllowAllNonPackagedSubkeys(const std::wstring& nonPackagedKeyPath) {
  int updated = 0;
  HKEY hKey = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, nonPackagedKeyPath.c_str(), 0, KEY_READ | KEY_WRITE, &hKey) != ERROR_SUCCESS || hKey == nullptr) {
    return 0;
  }

  std::vector<std::wstring> childNames;
  DWORD index = 0;
  wchar_t subKeyName[1024];
  for (;;) {
    DWORD nameLen = static_cast<DWORD>(std::size(subKeyName));
    LONG enumRes = ::RegEnumKeyExW(hKey, index, subKeyName, &nameLen, nullptr, nullptr, nullptr, nullptr);
    if (enumRes == ERROR_NO_MORE_ITEMS) {
      break;
    }
    if (enumRes == ERROR_SUCCESS && nameLen > 0) {
      childNames.emplace_back(subKeyName, nameLen);
    }
    ++index;
  }
  ::RegCloseKey(hKey);

  for (const auto& child : childNames) {
    if (WriteRegAllowString(HKEY_CURRENT_USER, nonPackagedKeyPath + L"\\" + child)) {
      ++updated;
    }
  }
  return updated;
}

bool IsMachineWideCameraBlocked() {
  // 1. Check HKLM ConsentStore\webcam -> Value == "Deny"
  HKEY hKey = nullptr;
  if (::RegOpenKeyExW(
          HKEY_LOCAL_MACHINE,
          L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam",
          0,
          KEY_READ,
          &hKey) == ERROR_SUCCESS && hKey != nullptr) {
    wchar_t buf[64] = {0};
    DWORD bufBytes = sizeof(buf);
    DWORD type = 0;
    if (::RegQueryValueExW(hKey, L"Value", nullptr, &type, reinterpret_cast<LPBYTE>(buf), &bufBytes) == ERROR_SUCCESS &&
        type == REG_SZ) {
      if (_wcsicmp(buf, L"Deny") == 0) {
        ::RegCloseKey(hKey);
        return true;
      }
    }
    ::RegCloseKey(hKey);
  }

  // 2. Check Group Policy LetAppsAccessCamera == 2 (Force Deny)
  HKEY hPol = nullptr;
  if (::RegOpenKeyExW(
          HKEY_LOCAL_MACHINE,
          L"SOFTWARE\\Policies\\Microsoft\\Windows\\AppPrivacy",
          0,
          KEY_READ,
          &hPol) == ERROR_SUCCESS && hPol != nullptr) {
    DWORD val = 0;
    DWORD valSize = sizeof(val);
    DWORD type = 0;
    if (::RegQueryValueExW(hPol, L"LetAppsAccessCamera", nullptr, &type, reinterpret_cast<LPBYTE>(&val), &valSize) == ERROR_SUCCESS &&
        type == REG_DWORD && val == 2) {
      ::RegCloseKey(hPol);
      return true;
    }
    ::RegCloseKey(hPol);
  }

  return false;
}

flutter::EncodableMap ForceWindowsCameraAndMicAccess(bool elevateIfBlocked) {
  const std::wstring kWebcamKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam";
  const std::wstring kWebcamNonPackaged = kWebcamKey + L"\\NonPackaged";
  const std::wstring kMicKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone";
  const std::wstring kMicNonPackaged = kMicKey + L"\\NonPackaged";

  bool hkcuOk = true;
  hkcuOk = WriteRegAllowString(HKEY_CURRENT_USER, kWebcamKey) && hkcuOk;
  hkcuOk = WriteRegAllowString(HKEY_CURRENT_USER, kWebcamNonPackaged) && hkcuOk;
  hkcuOk = WriteRegAllowString(HKEY_CURRENT_USER, kMicKey) && hkcuOk;
  hkcuOk = WriteRegAllowString(HKEY_CURRENT_USER, kMicNonPackaged) && hkcuOk;

  int subkeysUpdated = 0;
  subkeysUpdated += ForceAllowAllNonPackagedSubkeys(kWebcamNonPackaged);
  subkeysUpdated += ForceAllowAllNonPackagedSubkeys(kMicNonPackaged);

  // Also explicitly register current executable path (with '\' replaced by '#') as "Allow"
  wchar_t exePathBuf[MAX_PATH] = {0};
  DWORD exeLen = ::GetModuleFileNameW(nullptr, exePathBuf, MAX_PATH);
  if (exeLen > 0 && exeLen < MAX_PATH) {
    std::wstring encodedExe(exePathBuf, exeLen);
    std::replace(encodedExe.begin(), encodedExe.end(), L'\\', L'#');
    if (WriteRegAllowString(HKEY_CURRENT_USER, kWebcamNonPackaged + L"\\" + encodedExe)) {
      ++subkeysUpdated;
    }
    if (WriteRegAllowString(HKEY_CURRENT_USER, kMicNonPackaged + L"\\" + encodedExe)) {
      ++subkeysUpdated;
    }
  }

  bool hklmBlocked = IsMachineWideCameraBlocked();
  if (hklmBlocked && elevateIfBlocked) {
    std::wstring cmdArgs =
        L"/c reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam\" /v Value /t REG_SZ /d Allow /f"
        L" & reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam\\NonPackaged\" /v Value /t REG_SZ /d Allow /f"
        L" & reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone\" /v Value /t REG_SZ /d Allow /f"
        L" & reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone\\NonPackaged\" /v Value /t REG_SZ /d Allow /f"
        L" & reg delete \"HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\AppPrivacy\" /v LetAppsAccessCamera /f";

    SHELLEXECUTEINFOW sei = {sizeof(sei)};
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";
    sei.lpFile = L"cmd.exe";
    sei.lpParameters = cmdArgs.c_str();
    sei.nShow = SW_HIDE;
    if (::ShellExecuteExW(&sei)) {
      if (sei.hProcess != nullptr) {
        ::WaitForSingleObject(sei.hProcess, 15000);
        ::CloseHandle(sei.hProcess);
      }
      hklmBlocked = IsMachineWideCameraBlocked();
    }
  }

  return flutter::EncodableMap{
      {flutter::EncodableValue("hkcuAllowed"), flutter::EncodableValue(hkcuOk)},
      {flutter::EncodableValue("hklmBlocked"), flutter::EncodableValue(hklmBlocked)},
      {flutter::EncodableValue("subkeysUpdated"), flutter::EncodableValue(subkeysUpdated)},
  };
}

}  // namespace

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
        } else if (method == "forceCameraAccess") {
          bool elevateIfBlocked = false;
          const auto* args = call.arguments();
          if (args != nullptr && std::holds_alternative<flutter::EncodableMap>(*args)) {
            const auto& map = std::get<flutter::EncodableMap>(*args);
            auto it = map.find(flutter::EncodableValue("elevateIfBlocked"));
            if (it != map.end() && std::holds_alternative<bool>(it->second)) {
              elevateIfBlocked = std::get<bool>(it->second);
            }
          }
          auto statusMap = ForceWindowsCameraAndMicAccess(elevateIfBlocked);
          result->Success(flutter::EncodableValue(statusMap));
        } else if (method == "openWindowsCameraSettings") {
          ::ShellExecuteW(nullptr, L"open", L"ms-settings:privacy-webcam", nullptr, nullptr, SW_SHOWNORMAL);
          result->Success(flutter::EncodableValue(true));
        } else if (method == "cleanup") {
          CleanupKioskHook();
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
}
