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

6. **Mobile (Android & iOS): WebView + Word, Excel, PowerPoint**:
   - Menu **Utilities** di top bar membuka Microsoft Word / Excel / PowerPoint (fallback ke Play Store / App Store bila belum terinstal).
   - Link atau unduhan dokumen `.doc/.docx/.xls/.xlsx/.ppt/.pptx` dari portal otomatis diunduh (dengan cookie sesi login) lalu dibuka di aplikasi Office yang sesuai.
     - **Android**: langsung terbuka di aplikasi Office (via `FileProvider`).
     - **iOS**: muncul lembar **"Open in…"** sistem, pilih Word/Excel/PowerPoint (batasan iOS: aplikasi tidak bisa memilih aplikasi tujuan secara langsung). Bila Office belum terinstal, dokumen ditampilkan dalam pratinjau.
   - Selama ujian, setelah Office dibuka peserta bebas berpindah ARA ⇄ Office sampai ujian selesai; berpindah ke aplikasi lain tanpa membuka Office tetap tercatat sebagai pelanggaran.
   - Selama ujian hanya dokumen Office yang boleh dibuka; link `tel:`/`mailto:`/aplikasi lain diblokir.
   - iOS: kamera/mikrofon proctoring memerlukan `NSCameraUsageDescription` & `NSMicrophoneUsageDescription` di `Info.plist` (sudah dikonfigurasi). Gesture swipe-back WebView dinonaktifkan.

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

### 6. Build iOS (wajib di Mac)
iOS tidak dapat di-build dari Windows. Di Mac (Xcode terinstal), project memakai Swift Package Manager:
```bash
fvm flutter build ios --no-codesign
# atau jalankan di iPhone:
fvm flutter run -d <id-iphone>
```
Setelah mengubah key izin di `Info.plist`, hapus cache Xcode sekali agar `permission_handler` membaca ulang izin:
`rm -rf ~/Library/Developer/Xcode/DerivedData`

---

## 📂 Struktur Proyek

```
lib/
├── main.dart                          # Inisialisasi WindowManager, KioskService, & Root Theme
├── services/
│   ├── kiosk_security_service.dart    # Win32 Watchdog & Enforcer + Mobile lifecycle / Office session
│   ├── assessment_detector.dart       # Detektor URL route, DOM observer, & JS Bridge
│   ├── office_launcher_service.dart   # Membuka Word/Excel/PowerPoint (Windows, macOS, Android, iOS)
│   └── office_document_service.dart   # Unduh dokumen portal (cookie sesi) & buka di aplikasi Office (mobile)
└── ui/
    └── webview_screen.dart            # InAppWebView full-bleed, auto-grant kamera, dialog pengawas
android/app/src/main/kotlin/.../
├── MainActivity.kt                    # Channel ara_desktop/mobile_kiosk (FLAG_SECURE, launchPackage, openDocument)
└── AraDocumentFileProvider.kt         # FileProvider untuk berbagi dokumen ke aplikasi Office
ios/Runner/AppDelegate.swift           # AraMobileKioskPlugin: openDocument via "Open in…" sheet
test/
├── widget_test.dart                   # Unit test suite untuk KioskSecurityService & AssessmentDetector
├── kiosk_security_policy_test.dart    # Kebijakan watchdog & lifecycle sesi Office mobile
└── office_document_service_test.dart  # Deteksi jenis dokumen, nama file, & MIME
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
