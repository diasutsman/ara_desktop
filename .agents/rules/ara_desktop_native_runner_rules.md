# ARA Desktop C++ Runner & Native Menu Rules

1. **Header Integrity Invariants**:
   - Saat memodifikasi file header C++ runner (`kiosk_hook.h`, `flutter_window.h`, `win32_window.h`), pastikan seluruh deklarasi fungsi yang sudah ada (seperti `IsWindowControlsLocked()`) TIDAK terhapus atau tertimpa.
   - Selalu sertakan `<string>` jika fungsi menggunakan `const std::string&`.

2. **Native Win32 Menu Preference**:
   - Untuk kebutuhan menu bar native Windows (klasik Win32 / WinForms MenuStrip), gunakan Win32 API (`CreateMenu()`, `CreatePopupMenu()`, `AppendMenuW()`, `SetMenu()`, `DrawMenuBar()`) langsung pada `HWND` di C++ runner.
   - Jangan menggunakan custom Flutter widget untuk menu bar jika pengguna meminta menu bar native ("JANGAN CUSTOM").
   - Tangani interaksi menu via pesan `WM_COMMAND` di `FlutterWindow::MessageHandler` dan teruskan event ke Dart melalui `MethodChannel` (`NotifyOfficeAppLaunched`).

3. **Restricted Mode Window Architecture**:
   - Di mode restricted (ujian/kiosk), kontrol jendela native Windows (minimize, maximize/restore, close) dicopot bit style-nya via `WS_SYSMENU`, `WS_MINIMIZEBOX`, `WS_MAXIMIZEBOX` di C++ runner (`SetWindowLongPtr`).
   - Title bar dan native `HMENU` tetap tampil dan aktif tanpa tombol minimize, maximize, atau close.

4. **Initial Landing URL**:
   - Aplikasi selalu mengarah ke `https://ara-assessment.com/assess/login` sebagai landing page utama saat startup.
