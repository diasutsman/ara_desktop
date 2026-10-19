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
- **Platform Parity Invariant**: Every WebView or Office feature added for Windows MUST also be
  implemented and verified for Android & iOS (Dart branch + native channel + manifest/plist entries).
  Desktop-only hooks must be guarded with `Platform.isWindows/isMacOS`, mobile hooks with `_isMobile`.
- **Navigation Lock**:
  - Wrap root view with `PopScope(canPop: !isExam)` to block Android system back gestures/buttons during exams.
- **Immersive Mode**:
  - Activate `SystemUiMode.immersiveSticky` in exam mode to hide the status bar and system navigation bar; restore `SystemUiMode.edgeToEdge` in normal mode.
- **Screen Protection**:
  - Enforce `FLAG_SECURE` on Android via native `MethodChannel("ara_desktop/mobile_kiosk")` to block screenshots and screen recordings during exams.
- **Multi-App Lifecycle & Office Session**:
  - Manage authorized app switching using an `isOfficeSessionActive` session flag.
  - When the user launches Word/Excel/PPT via the Utilities menu OR opens a portal document, set `isOfficeSessionActive = true`.
  - The session persists for the whole exam (parity with desktop Alt+Tab); it is cleared only when mode returns to `normal`.
  - On app pause/resume:
    - If `isOfficeSessionActive == true`: allow the switch without penalty.
    - If `isOfficeSessionActive == false` and in exam mode: record a security violation (`violationCount++`) and trigger a warning alert.
    - On resume during an exam, re-apply `SystemUiMode.immersiveSticky`.
- **Package Visibility & URI Schemes**:
  - Android: Declare `<queries>` in `AndroidManifest.xml` for `com.microsoft.office.*` and schemes `ms-word`, `ms-excel`, `ms-powerpoint`, `ms-office`.
  - iOS: Declare `LSApplicationQueriesSchemes` in `Info.plist` for `ms-word`, `ms-excel`, `ms-powerpoint`, `ms-office`.
  - Fallback: Direct users to official Google Play Store or Apple App Store links when an app is not installed.
- **Opening Portal Documents (.doc/.docx/.xls/.xlsx/.ppt/.pptx)**:
  - Mobile WebView uses `useShouldOverrideUrlLoading` + `useOnDownloadStart`; pass the callbacks as `null` on desktop
    (flutter_inappwebview auto-enables the hooks when a callback is set).
  - Download with per-host CookieManager cookies (manual redirects) into `getTemporaryDirectory()/ara_documents/`.
  - Open via `ara_desktop/mobile_kiosk` → `openDocument`: Android = `AraDocumentFileProvider` + `ACTION_VIEW` targeted at the Office package;
    iOS = `UIDocumentInteractionController` "Open in…" sheet (iOS cannot target a specific app).
  - Android `<queries>` must include `ACTION_VIEW` + each Office MIME type.
- **iOS Native Channel**: `AraMobileKioskPlugin` lives inside `ios/Runner/AppDelegate.swift` (avoids hand-editing
  `project.pbxproj` from Windows), registered in `didInitializeImplicitFlutterEngine` via `engineBridge.pluginRegistry.registrar(forPlugin:)`.

## 5. Mobile (Android & iOS) WebView Reliability & Branding Invariants
- **iOS Permissions (Swift Package Manager project)**:
  - `ios/Runner/Info.plist` MUST contain `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`.
    `permission_handler_apple` (SwiftPM) enables permissions ONLY from these keys; missing keys = crash/denied. No Podfile macros needed.
  - iOS cannot be built on the Windows workstation; flag Swift changes for verification on a Mac (`flutter build ios --no-codesign`).
- **Network & SSL Resilience**:
  - In `AndroidManifest.xml`, configure `android:usesCleartextTraffic="true"` inside `<application>`.
  - In `InAppWebViewSettings`:
    - Set `mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW`.
    - Set `thirdPartyCookiesEnabled: true`, `domStorageEnabled: true`, `databaseEnabled: true`.
    - Provide a platform-specific `userAgent`: Chrome Mobile on Android, Mobile Safari on iOS, `null` on desktop.
    - On iOS set `allowsBackForwardNavigationGestures: false` and `allowsLinkPreview: false` (swipe-back bypasses `PopScope`).
  - Implement `onReceivedServerTrustAuthRequest`:
    - For target assessment domains (`ara-assessment.com`), return `ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.PROCEED)` to prevent silent drops from TLS renegotiation or intermediate certificate validation.
- **Visual Branding & App Name**:
  - In `android/app/src/main/AndroidManifest.xml`: set `android:label="ARA Mobile"`.
  - In `ios/Runner/Info.plist`: set `CFBundleDisplayName` and `CFBundleName` to `ARA Mobile`.
  - In `_buildMobileTopBar`: use official `assets/icon/app_icon.png` with rounded corners next to the text `ARA Mobile`.

## 6. macOS Desktop Kiosk Lockdown
- **Multi-Desktop (Spaces) & Trackpad 3-Finger Swipe Protection**:
  - In `macos/Runner/MainFlutterWindow.swift`, apply `collectionBehavior`:
    `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`
    - `.canJoinAllSpaces`: The window is pinned across ALL macOS Spaces (virtual desktops). When the user swipes 3 fingers left or right to switch spaces, the window remains visible and stays pinned on all spaces, preventing any peek or switch to another desktop or application.
    - `.fullScreenAuxiliary` & `.stationary`: Prevents the window from creating an isolated Space or animating during Exposé/Space transitions.
  - Window level: Set to `.screenSaver` (above normal apps, Dock, and Menu Bar) during lockdown, and `.normal` during authorized Office sessions.
  - Presentation Options:
    `[.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit, .disableSessionTermination, .disableHideApplication, .disableAppleMenu]`
    - `.disableProcessSwitching`: Disables `Cmd + Tab` and 3/4-finger swipe gestures for Mission Control and Exposé.
- **Trackpad Gesture Suppression**:
  - Override `swipe(with:)` and `scrollWheel(with:)` on `MainFlutterWindow`, plus `NSEvent.addLocalMonitorForEvents(matching: [.swipe])` returning `nil`.
- **Application Switching Watchdog**:
  - Observe `NSWorkspace.didActivateApplicationNotification`.
  - If an unauthorized app becomes active, immediately call `forceForeground()` (`NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront(nil)`) and invoke `onNavigationBlocked` (`reason: "minimize"`) on MethodChannel `ara_desktop/macos_kiosk`.
- **Parity with Mobile Always-On Kiosk**:
  - In `KioskSecurityService.initialize()`, engage `setMode(AssessmentMode.exam)` on startup for macOS (`Platform.isMacOS`).
  - In `lib/main.dart`, do not constrain the window to 1366x768 on macOS (`waitUntilReadyToShow(null, ...)`).

## 7. Development Mode & Proctoring Watchdog Invariants
- **Preserving Proctoring During Dev Testing**:
  - `DEV_MODE=true` provides developer conveniences (window exit with `Esc`/`Ctrl+Q`, supervisor dialog on `F12`, DevTools inspectable WebView `isInspectable: true`, server toggle `Ctrl+Shift+L` between localhost and production).
  - **CRITICAL INVARIANT**: Development mode MUST NOT disable the 200ms proctoring watchdog timer or suppress unauthorized window detection (`_blockUnauthorizedWindow`). Developers test proctoring by switching to other apps; if the watchdog is stopped or alerts are bypassed, app switching detection fails completely.
  - `DEV_BYPASS_LOCKDOWN` in `.env` must default to `false`. When `devBypassLockdown` is toggled on via the F12 panel, it should only bypass forced window maximization/fullscreen layout, while still actively monitoring and detecting unauthorized apps in exam mode.
  - `DEV_RECORD_VIOLATIONS` in `.env` must default to `true` so local backend test endpoints (`/Violation/record`) and in-page JavaScript violation bridges receive test events.

