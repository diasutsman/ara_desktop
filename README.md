# ARA Assessment - Flutter Cross-Platform Wrapper & Kiosk Security Guard

Aplikasi wrapper cross-platform (Windows Desktop, macOS, Android, iOS) untuk portal asesmen **https://ara-assessment.com** dengan fitur proctoring kamera WebRTC dan proteksi Lockdown Kiosk berbasis Win32 Watchdog.

---

## 🚀 Fitur Utama

1. **Clean Borderless Full-Bleed WebView**:
   - Menghilangkan AppBar dan seluruh chrome bawaan browser/aplikasi.
   - Menggunakan engine WebView modern (`flutter_inappwebview` v6) dengan WebView2 pada Windows.

2. **WebRTC Camera & Microphone Auto-Grant**:
   - Otomatis memberikan izin kamera dan mikrofon saat web portal meminta akses webcam untuk proctoring (`navigator.mediaDevices.getUserMedia`).
   - Telah dikonfigurasi pada Android Manifest (`CAMERA`, `RECORD_AUDIO`), macOS `Info.plist` & Entitlements, serta Windows WebView2 environment.

3. **Strict Assessment Lockdown (Ujian Reguler)**:
   - Window otomatis **Fullscreen**, **Always-On-Top**, dan **PreventClose**.
   - Background Watchdog memantau *foreground application* (setiap 400ms).
   - Jika peserta mencoba membuka aplikasi lain (Chrome, Edge, Telegram, Discord, Notepad, dll.) atau melakukan Alt-Tab, aplikasi tersebut otomatis diminimalkan/diblokir dan fokus dikembalikan seketika ke ARA Assessment dengan banner peringatan.

4. **Essay Assessment Whitelist (Mode Essay)**:
   - Pada sesi ujian essay, peserta diizinkan membuka dan menggunakan **Microsoft Word (`WINWORD.EXE`)** dan **Microsoft PowerPoint (`POWERPNT.EXE`)**.
   - Aplikasi non-whitelist (browser, chat, AI tools) tetap diblokir/diminimalkan secara otomatis.

5. **Deteksi Otomatis & Supervisor Shortcut**:
   - Mendeteksi route ujian (`/ujian`, `/assessment`, `/exam`, `/soal`, `/essay`) dan halaman selesai (`/selesai`, `/dashboard`, `/login`) secara otomatis melalui URL dan DOM Mutation Observer.
   - **Shortcut Pengawas / Debugger**: Tekan `Ctrl + Shift + F12` atau `Alt + F12` (atau double-tap badge status) untuk membuka dialog kontrol manual pengawas (mengubah mode ke Normal, Strict, atau Essay, serta reload web).

---

## 🛠️ Prasyarat & Lingkungan

- **Flutter**: 3.47.5 (Channel Stable)
- **Dart**: 3.13.4
- **FVM**: 4.x
- **Target OS**: Windows 10/11 (Primary), macOS, Android, iOS

---

## 💻 Cara Menjalankan

### 1. Pastikan FVM Aktif
```bash
fvm use 3.47.5
```

### 2. Jalankan di Desktop Windows (Debug Mode)
```bash
fvm flutter run -d windows
```

### 3. Jalankan di Android / macOS
```bash
fvm flutter run -d android
# atau
fvm flutter run -d macos
```

### 4. Menjalankan Unit Test
```bash
fvm flutter test
```

### 5. Build Release Windows Binary (.exe)
```bash
fvm flutter build windows --release
```
Hasil build akan berada di:  
`build/windows/x64/runner/Release/`

---

## 📂 Struktur Proyek

```
lib/
├── main.dart                          # Inisialisasi WindowManager, KioskService, & Root Theme
├── services/
│   ├── kiosk_security_service.dart    # Win32 Watchdog & Enforcer (Strict vs Essay Whitelist)
│   └── assessment_detector.dart       # Detektor URL route, DOM observer, & JS Bridge
└── ui/
    └── webview_screen.dart            # InAppWebView full-bleed, auto-grant kamera, dialog pengawas
test/
└── widget_test.dart                   # Unit test suite untuk KioskSecurityService & AssessmentDetector
```

---

## 🛡️ Integrasi Khusus Web (Opsional)

Jika tim web ara-assessment.com ingin mengontrol status ujian secara langsung melalui JavaScript (tanpa bergantung deteksi URL), cukup panggil fungsi berikut dari script web:

```javascript
// Mengaktifkan mode lockdown ketat (semua aplikasi lain diblokir)
window.setAraAssessmentMode('strict');

// Mengaktifkan mode essay (Word & PowerPoint diizinkan)
window.setAraAssessmentMode('essay');

// Keluar dari mode ujian (kembali ke window normal)
window.setAraAssessmentMode('normal');
```
Aplikasi Flutter akan menangkap panggilan ini seketika.
