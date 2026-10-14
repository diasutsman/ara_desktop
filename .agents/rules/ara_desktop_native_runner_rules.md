# ARA Desktop C++ Runner & Native Menu Rules

1. **Header Integrity Invariants**:
   - Saat memodifikasi file header C++ runner (`kiosk_hook.h`, `flutter_window.h`, `win32_window.h`), pastikan seluruh deklarasi fungsi yang sudah ada (seperti `IsWindowControlsLocked()`) TIDAK terhapus atau tertimpa.
   - Selalu sertakan `<string>` jika fungsi menggunakan `const std::string&`.

2. **Native Win32 Menu Preference**:
   - Untuk kebutuhan menu bar native Windows (klasik Win32 / WinForms MenuStrip), gunakan Win32 API (`CreateMenu()`, `CreatePopupMenu()`, `AppendMenuW()`, `SetMenu()`, `DrawMenuBar()`) langsung pada `HWND` di C++ runner.
   - Jangan menggunakan custom Flutter widget untuk menu bar jika pengguna meminta menu bar native ("JANGAN CUSTOM").
   - Tangani interaksi menu via pesan `WM_COMMAND` di `FlutterWindow::MessageHandler` dan teruskan event ke Dart melalui `MethodChannel` (`NotifyOfficeAppLaunched`).

3. **Restricted Mode Window Architecture & Menu Bar Visibility**:
   - Di mode restricted (ujian/kiosk), kontrol jendela native Windows (minimize, maximize) dicopot bit style-nya via `WS_MINIMIZEBOX` dan `WS_MAXIMIZEBOX`.
   - **DILARANG MENCOPO WS_SYSMENU**: Mencopot bit `WS_SYSMENU` merusak pelacakan native menu Win32 dan membuat menu bar hilang atau berwarna putih.
   - Untuk menonaktifkan tombol Close ('X') secara native, gunakan `::EnableMenuItem(::GetSystemMenu(hwnd, FALSE), SC_CLOSE, MF_BYCOMMAND | MF_DISABLED | MF_GRAYED)` dan cegah pesan `SC_CLOSE` pada `WM_SYSCOMMAND`.
   - Title bar dan native `HMENU` ("Utilities") WAJIB selalu tampil dan aktif. Panggil `::DrawMenuBar(hwnd)` setiap kali status lock window diubah.
   - **DILARANG MEMANGGIL `SetWindowTheme(hwnd, L"DarkMode_Explorer", nullptr)`** pada jendela utama ber-menu bar karena `DarkMode_Explorer` secara default menyembunyikan classic menu bar Win32.

4. **Initial Landing URL**:
   - Aplikasi selalu mengarah ke `https://ara-assessment.com/assess/login` sebagai landing page utama saat startup.
