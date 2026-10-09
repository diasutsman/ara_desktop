# Flutter Windows Kiosk & Exam Lockdown Best Practices

## 1. System Shortcut Interception (Alt+Tab, WinKey, Ctrl+Esc, Alt+Esc, Alt+F4)
- **Problem**: Flutter Dart layer listeners (`HardwareKeyboard`, `FocusNode`) TIDAK BISA membatalkan atau menelan (*swallow*) shortcut sistem tingkat OS seperti `Alt + Tab` atau `Windows Key` karena Windows DWM/Shell mencegatnya di kernel level sebelum event sampai ke aplikasi.
- **Solution**: Pasang Win32 Low-Level Keyboard Hook (`SetWindowsHookEx(WH_KEYBOARD_LL, LowLevelKeyboardProc, ...)`) di layer native C++ Runner (`windows/runner/kiosk_hook.cpp`).
- **Communication**: Hubungkan aktifasi hook antara Flutter Dart dan C++ Runner menggunakan `MethodChannel` (`ara_desktop/kiosk_hook`).

## 2. Window State Hierarchy & Enforcement
- **Mode Strict Exam (Ujian Ketat)**:
  - Aktifkan `WH_KEYBOARD_LL` (telan `Alt + Tab`, `Win Key`, `Alt + Esc`, `Ctrl + Esc`, `Alt + F4` dengan mengembalikan nilai `1` pada hook proc).
  - Aktifkan `setFullScreen(true)`, `setAlwaysOnTop(true)`, dan `setPreventClose(true)`.
  - Pasang paksa refocus seketika pada event `onWindowBlur()`.
  - Background Watchdog memantau process foreground setiap 400ms untuk meminimalkan aplikasi lain jika ada yang mencoba dibuka.
- **Mode Essay Exam**:
  - Nonaktifkan `WH_KEYBOARD_LL` agar beralih antar aplikasi terdaftar (Word/PowerPoint) tetap lancar bagi siswa.
  - Pertahankan Watchdog berkala untuk meminimalkan aplikasi di luar whitelist.
- **Mode Normal (Dashboard/Login/Selesai)**:
  - Nonaktifkan hook keyboard.
  - Kembalikan jendela ke state standar (`setFullScreen(false)`).
  - Gunakan kontrol jendela native Windows (minimize, maximize, close) bawaan OS di title bar. Jangan menduplikasi tombol kustom di dalam webview.

## 3. Developer Safety
- Selalu sediakan bypass darurat (*emergency unhook*) seperti `Ctrl + Q` atau `Escape` agar developer tidak terkunci saat debugging di local machine.
- Lepas hook secara bersih (`UnhookWindowsHookEx`) saat `exitApp()` dan `OnDestroy()`.

## 4. State Priority & Manual Override Pattern
- **Manual Lock Hierarchy**:
  - Pilihan mode dari pengguna/pengawas (Manual Override) harus memiliki prioritas lebih tinggi daripada deteksi otomatis (URL sniffing / DOM scanning).
  - Saat mode manual dipilih, sistem harus menyetel `isManualOverride = true` dan mengabaikan event auto-detect berkala hingga pengguna secara eksplisit memilih "Mode Otomatis".
- **DOM Scanner Precision**:
  - JANGAN memindai teks bebas di `document.body.innerText` untuk menentukan state keamanan (misal `body.innerText.indexOf('essay')`), karena petunjuk halaman atau navbar dapat memicu *false positive*.
  - Gunakan elemen form spesifik (input/textarea ID), penanda route URL yang jelas, atau meta tags proctoring resmi.
  - Terapkan debouncing/memoization agar skrip JS hanya mengirim event ke Flutter jika state yang terdeteksi benar-benar berubah (`lastReportedState !== newState`).

## 5. Win32 Non-Client & System Command Interception (Toolbar Double-Click & Drag Protection)
- **Problem**: Pengguna dapat melakukan double-click pada toolbar / caption bar atas untuk mengecilkan (*restore*) jendela dari fullscreen atau mengklik tombol caption.
- **Solution**:
  - Di `FlutterWindow::MessageHandler` (`windows/runner/flutter_window.cpp`), saat mode lockdown aktif (`IsKioskWindowLocked()`):
    - Cegat `WM_NCLBUTTONDBLCLK`: kembalikan `0` agar Windows tidak memicu unmaximize/restore pada double-click area toolbar/caption.
    - Cegat `WM_SYSCOMMAND`: jika perintah adalah `SC_MINIMIZE`, `SC_RESTORE`, `SC_MOVE`, `SC_SIZE`, `SC_CLOSE`, atau `SC_KEYMENU`, kembalikan `0` (tolak perintah sistem).
    - Cegat `WM_NCLBUTTONDOWN`: jika di `HTMINBUTTON`, `HTMAXBUTTON`, `HTCLOSE`, atau `HTCAPTION`, kembalikan `0` (tidak bisa didrag atau diklik).
    - Cegat `WM_NCRBUTTONDOWN` / `WM_NCRBUTTONUP`: kembalikan `0` untuk memblokir menu konteks klik kanan pada title bar.
  - Di layer Flutter Dart:
    - Set `setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false)`
    - Set `setResizable(false)`, `setMinimizable(false)`, dan `setMaximizable(false)`
    - Set `setFullScreen(true)` dan `setAlwaysOnTop(true)`.

## 6. Essay Mode Kiosk Pattern (Taskbar Access & Whitelist Enforcer)
- **Window Geometry**: Gunakan `setFullScreen(false)` + `maximize()` + `setTitleBarStyle(TitleBarStyle.hidden)` agar Taskbar Windows tetap terbuka untuk mengakses Word/PPT, namun jendela ujian tidak memiliki kontrol untuk ditutup, diminimalkan, atau di-resize.
- **Controls Locking**: Tetap aktifkan kunci Win32 (`SC_CLOSE`, `SC_MINIMIZE`, `SC_RESTORE`, `WM_NCLBUTTONDBLCLK`) pada jendela ujian di Mode Essay melalui `SetWindowControlsLocked(true)`.
- **Aggressive Unauthorized App Minimization & Refocus**:
  - JANGAN sertakan browser (`chrome.exe`, `msedge.exe`, `firefox.exe`, dll.) pada whitelist apa pun.
  - Saat proses non-whitelist terdeteksi di foreground (polling 200ms), minimalkan seketika (`ShowWindow(hwnd, SW_MINIMIZE)`) dan panggil `windowManager.focus()` untuk mengembalikan jendela ujian ke depan.
  - Izinkan `winword.exe`, `powerpnt.exe`, serta komponen Windows Shell (`explorer.exe`, `startmenuexperiencehost.exe`) agar taskbar dan menu aplikasi bekerja dengan mulus.

## 7. Elevated Process & Zero-Name Watchdog Hardening
- Jangan pernah mengabaikan proses tanpa nama (`processExe.isEmpty`). Jika `activePid != ownPid` dan nama proses kosong, baca class jendela (`GetClassName`).
- Jika class jendela bukan class shell inti (`Shell_TrayWnd`, `Shell_SecondaryTrayWnd`, `Progman`, `WorkerW`), anggap proses tersebut sebagai aplikasi sistem elevated/terlarang (misal Device Manager / MMC, Regedit, Admin Console) dan segera blokir/minimalkan.

## 8. Native Win32 Foreground Takeover (ASFW Lockout Bypass)
- Jangan hanya mengandalkan `windowManager.focus()` saat ada aplikasi pihak ketiga (Word/PPT) yang diizinkan di Mode Essay.
- Di Windows OS, meminimalkan aplikasi terlarang (misal Excel) saat PowerPoint aktif akan mengaktifkan PowerPoint karena urutan Z-Order. Panggilan `SetForegroundWindow` dari background diblokir oleh Windows OS melalui *AllowSetForegroundWindow (ASFW)*.
- Implementasikan fungsi native C++ dengan `AttachThreadInput` ke thread jendela foreground saat ini, lalu naikkan jendela ke `HWND_TOPMOST` kemudian `HWND_NOTOPMOST`, panggil `SetForegroundWindow`, lalu lepas `AttachThreadInput`.
- Ini menjamin aplikasi ujian dapat langsung merebut fokus layar penuh ketika aplikasi terlarang (seperti Excel) diminimalkan.

## 9. Explorer.exe Class Filtering (Taskbar vs File Explorer)
- Saat mengizinkan `explorer.exe` untuk taskbar di Mode Essay, selalu validasi `className`:
  - `Shell_TrayWnd`, `Shell_SecondaryTrayWnd`, `Progman`, `WorkerW`: **ALLOWED** (Taskbar/Desktop)
  - `CabinetWClass`, `ExploreWClass`: **BLOCKED** (Jendela Folder File Explorer)
  - `#32770` dengan judul Run: **BLOCKED** (Kotak Dialog Run `Win+R`)

## 10. UWP Application Minimization
- Untuk meminimalkan aplikasi UWP Windows 10/11 (`ApplicationFrameHost.exe`), selalu kirim `PostMessage(hwnd, WM_SYSCOMMAND, const WPARAM(SC_MINIMIZE), const LPARAM(0))` bersamaan dengan `ShowWindow(hwnd, SW_MINIMIZE)`.
