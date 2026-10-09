# Flutter Desktop (Windows) with window_manager

When configuring `window_manager` for Flutter desktop on Windows to display a standard window with native caption buttons (minimize, maximize, close):
1. **Startup setFullScreen check**: Do NOT call `windowManager.setFullScreen(false)` during startup or inside `waitUntilReadyToShow`. Calling `setFullScreen(false)` on a window that was not previously fullscreen triggers the native C++ restore routine which overwrites `GWL_STYLE` without `WS_CAPTION`, stripping the native title bar. Only invoke `setFullScreen(false)` if `await windowManager.isFullScreen()` evaluates to `true`.
2. **Omit titleBarStyle for native title bar**: Do NOT specify `titleBarStyle: TitleBarStyle.normal` in `WindowOptions` when the standard native Win32 title bar is desired. Specifying it causes `window_manager` to invoke `DwmExtendFrameIntoClientArea` with `{0,0,0,0}`, which disrupts standard Win32 non-client frame rendering.
