# Flutter Desktop & Mobile Kiosk Guidelines

## 1. Environment & Workstation Configuration
- **Partition Allocation Strategy**:
  - **Drive C:** (~1.1 GB): Reserved exclusively for Windows OS and core system files. **NEVER** write large build caches or temp files here.
  - **Drive D:** (~186 GB free): Dedicated Gradle Home (`D:\Gradle`). All Gradle transforms, wrapper dists, and dependencies live here.
  - **Drive E:** (~91 GB free): Workspaces and temp directory (`E:\Temp`).
- **Command Invariant for PowerShell**:
  - Prepend environment overrides to all Flutter, Dart, and Android commands:
    ```powershell
    $env:JAVA_HOME='C:\Users\Dias\.jdks\temurin-17'; $env:GRADLE_USER_HOME='D:\Gradle'; $env:TEMP='E:\Temp'; $env:TMP='E:\Temp';
    ```
- **Android Gradle Invariants**:
  - In `android/gradle.properties`: always keep `systemProp.gradle.user.home=D:/Gradle`.
  - In `android/gradlew.bat`: default `GRADLE_USER_HOME` to `D:\Gradle` if not defined.
- **Recovering from Corrupted Gradle State**:
  - If a Gradle build fails and locks files, terminate daemons first:
    ```powershell
    Get-Process -Name java* -ErrorAction SilentlyContinue | Stop-Process -Force
    ```
  - Clean corrupted cache folders with fast `cmd.exe /c rmdir /s /q`.

## 2. Windows Desktop Native Win32 Dark Menu Bar
- **Problem**: Classic Win32 `HMENU` bars created via `::CreateMenu()` / `::SetMenu()` default to bright white on Windows 10/11 even when the window frame has dark mode enabled.
- **Solution**:
  - Intercept undocumented User32 Aero Hook (UAH) messages in the window procedure:
    - `WM_UAHDRAWMENU` (`0x0091`): Paint background with the window title bar color (`RGB(43, 43, 43)` / `#2B2B2B`).
    - `WM_UAHDRAWMENUITEM` (`0x0092`): Draw menu text and handle selection/hover highlights.
    - `WM_NCPAINT` & `WM_NCACTIVATE`: Call `UAHDrawMenuNCBottomLine` to erase light visual seams.
  - For popup dropdown menus, dynamically invoke `uxtheme.dll` ordinals:
    - Ordinal 135: `SetPreferredAppMode(ForceDark)`
    - Ordinal 133: `AllowDarkModeForWindow(hwnd, TRUE)`
    - Ordinal 136: `FlushMenuThemes()`
  - Synchronize window caption attributes via `DwmSetWindowAttribute`:
    - `DWMWA_CAPTION_COLOR = RGB(43, 43, 43)`
    - `DWMWA_TEXT_COLOR = RGB(255, 255, 255)`

## 3. Unified Exam Assessment Mode
- **Pattern**: When unifying exam modes (e.g., standard exam and essay exam), allow Office utilities (Word, Excel, PowerPoint) by default while blocking all unauthorized browsers and third-party apps within 200ms.
- **Window Management**:
  - Set window to Maximized with bit styles `WS_SYSMENU`, `WS_MINIMIZEBOX`, and `WS_MAXIMIZEBOX` stripped.
  - Intercept `WM_SYSCOMMAND` and `WM_NCLBUTTONDBLCLK` to prevent window un-maximizing or closing.

## 4. Mobile (Android & iOS) Kiosk & Office Integration
- **Navigation Lock**:
  - Wrap root view with `PopScope(canPop: !isExam)` to block Android system back gestures/buttons during exams.
- **Immersive Mode**:
  - Activate `SystemUiMode.immersiveSticky` in exam mode to hide the status bar and system navigation bar; restore `SystemUiMode.edgeToEdge` in normal mode.
- **Screen Protection**:
  - Enforce `FLAG_SECURE` on Android via native `MethodChannel("ara_desktop/mobile_kiosk")` to block screenshots and screen recordings during exams.
- **Multi-App Lifecycle & Office Session**:
  - Manage authorized app switching using an `isOfficeSessionActive` session flag.
  - When the user launches Word/Excel/PPT via the Utilities menu, set `isOfficeSessionActive = true`.
  - On app pause/resume:
    - If `isOfficeSessionActive == true`: allow the switch without penalty.
    - If `isOfficeSessionActive == false` and in exam mode: record a security violation (`violationCount++`) and trigger a warning alert.
- **Package Visibility & URI Schemes**:
  - Android: Declare `<queries>` in `AndroidManifest.xml` for `com.microsoft.office.*` and schemes `ms-word`, `ms-excel`, `ms-powerpoint`, `ms-office`.
  - iOS: Declare `LSApplicationQueriesSchemes` in `Info.plist` for `ms-word`, `ms-excel`, `ms-powerpoint`, `ms-office`.
  - Fallback: Direct users to official Google Play Store or Apple App Store links when an app is not installed.

## 5. Mobile (Android & iOS) WebView Reliability & Branding Invariants
- **Network & SSL Resilience**:
  - In `AndroidManifest.xml`, configure `android:usesCleartextTraffic="true"` inside `<application>`.
  - In `InAppWebViewSettings`:
    - Set `mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW`.
    - Set `thirdPartyCookiesEnabled: true`, `domStorageEnabled: true`, `databaseEnabled: true`.
    - Provide a modern Mobile Chrome `userAgent` to prevent restrictive `wv` bot filtering.
  - Implement `onReceivedServerTrustAuthRequest`:
    - For target assessment domains (`ara-assessment.com`), return `ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.PROCEED)` to prevent silent drops from TLS renegotiation or intermediate certificate validation.
- **Visual Branding & App Name**:
  - In `android/app/src/main/AndroidManifest.xml`: set `android:label="ARA Mobile"`.
  - In `ios/Runner/Info.plist`: set `CFBundleDisplayName` and `CFBundleName` to `ARA Mobile`.
  - In `_buildMobileTopBar`: use official `assets/icon/app_icon.png` with rounded corners next to the text `ARA Mobile`.
  - Display a branded ARA loading overlay while the WebView loads to prevent unstyled blank white frames.

