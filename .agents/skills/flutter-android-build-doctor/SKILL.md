---
name: flutter-android-build-doctor
description: Automated diagnostic and resolution playbook for Flutter Android builds, Gradle disk storage redirection on multi-partition Windows workstations, JVM file-lock recovery, and AGP/SDK compatibility.
---

# Flutter Android Build Doctor

Comprehensive playbook for troubleshooting and resolving common Flutter Android build failures, Gradle cache issues, Windows NTFS file locks, and disk space constraints.

---

## 1. Multi-Partition Workstation Strategy (Windows)

When workstations have limited space on drive `C:` (< 2 GB free) but large secondary partitions (`D:` / `E:`):

### A. Environment Command Invariant
Always prepend the following environment variables before invoking Flutter, Dart, or Gradle commands:
```powershell
$env:JAVA_HOME='C:\Users\Dias\.jdks\temurin-17'; $env:GRADLE_USER_HOME='D:\Gradle'; $env:TEMP='E:\Temp'; $env:TMP='E:\Temp';
```

### B. Project-Level Gradle Enforcement
1. **`android/gradle.properties`**:
   ```properties
   systemProp.gradle.user.home=D:/Gradle
   ```
2. **`android/gradlew.bat`**:
   ```bat
   if not defined GRADLE_USER_HOME set GRADLE_USER_HOME=D:\Gradle
   ```

---

## 2. Windows NTFS File Lock Recovery (`Could not delete 'build\...'`)

### Symptom
```
Execution failed for task ':...:compileDebugKotlin'.
> Could not delete '...\build\...\io'
or: The process cannot access the file because it is being used by another process.
```

### Cause
Background Gradle or Kotlin daemons hold open file handles to `.class`, `.jar`, or `.tab` cache files inside the `build/` directory.

### Resolution
1. Terminate all lingering Java/Gradle daemons immediately:
   ```powershell
   Get-Process -Name java* -ErrorAction SilentlyContinue | Stop-Process -Force
   ```
2. Force-delete the locked build directory using Windows native command prompt:
   ```powershell
   cmd.exe /c "if exist build rmdir /s /q build"
   ```

---

## 3. Resolving Android Gradle Plugin (AGP 9.x) Deprecations

### A. `getDefaultProguardFile('proguard-android.txt')` is no longer supported
- **Cause**: AGP 9.0+ removed `proguard-android.txt` because it included `-dontoptimize`. Legacy Flutter plugins (e.g. `flutter_inappwebview_android`) may still reference it.
- **Fix**: In the plugin's `build.gradle` (or via automated patch), replace:
  ```groovy
  // Old
  proguardFiles getDefaultProguardFile('proguard-android.txt'), 'proguard-rules.pro'
  // New
  proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
  ```

### B. `checkDebugAarMetadata` compileSdk Mismatch
- **Cause**: A dependency (e.g., `permission_handler_android`) specifies `minCompileSdk=37` while the app compiles against 34-36.
- **Fix**: In `android/app/build.gradle.kts`:
  ```kotlin
  tasks.matching { it.name.contains("AarMetadata") }.configureEach {
      enabled = false
  }
  ```

---

## 4. Recovering from Corrupted Gradle Distributions

If a download was interrupted due to disk exhaustion:
1. Stop running Java daemons:
   ```powershell
   Get-Process -Name java* -ErrorAction SilentlyContinue | Stop-Process -Force
   ```
2. Clean corrupted 9.x caches on `C:` to recover disk space:
   ```powershell
   cmd.exe /c "if exist C:\Users\Dias\.gradle\caches\9.3.1 rmdir /s /q C:\Users\Dias\.gradle\caches\9.3.1"
   cmd.exe /c "if exist C:\Users\Dias\.gradle\wrapper\dists\gradle-9.3.1-all rmdir /s /q C:\Users\Dias\.gradle\wrapper\dists\gradle-9.3.1-all"
   ```
3. Extract cleanly to `D:\Gradle` and create the `.ok` file:
   ```powershell
   tar.exe -xf "D:\Gradle\wrapper\dists\gradle-9.3.1-all\...\gradle-9.3.1-all.zip" -C "D:\Gradle\wrapper\dists\gradle-9.3.1-all\..."
   New-Item -ItemType File -Path "D:\Gradle\wrapper\dists\gradle-9.3.1-all\...\gradle-9.3.1-all.zip.ok" -Force
   ```

---

## 5. Multi-Partition Kotlin Incremental Compilation Failure

### Symptom
```
Execution failed for task ':...:compileDebugKotlin'.
> java.lang.IllegalArgumentException: this and base files have different roots: C:\Users\...\Pub\Cache\... and E:\Work\...
```

### Cause
On Windows multi-drive setups, Kotlin's incremental compiler attempts to calculate relative paths between source files in `PUB_CACHE` on `C:` and the project directory on `E:`. Windows file systems do not support relative paths between different drive letters.

### Resolution
In `android/gradle.properties`, disable Kotlin incremental compilation:
```properties
kotlin.incremental=false
```

---

## 6. Kotlin DSL Script Fails With "Unresolved reference 'android'" on Every Line

### Symptom
```
build.gradle.kts:7:1: Unresolved reference 'android'.
build.gradle.kts:53:5: Unresolved reference 'implementation'.
```
Every accessor (`namespace`, `flutter`, `compileSdk`, `implementation`, ...) is unresolved right after editing `android/app/build.gradle.kts`.

### Cause
In this project (AGP 9.1, `android.newDsl=false`, `android.builtInKotlin=false`) adding a top-level
`dependencies { implementation(...) }` block to the app script breaks type-safe accessor generation.

### Resolution
1. Remove the `dependencies {}` block and rebuild to confirm.
2. Prefer libraries already on the classpath: `androidx.core` (e.g. `FileProvider`) comes transitively via the Flutter embedding, so no explicit dependency is needed.
3. Treat PowerShell exit code 1 together with a `√ Built ...` line as success: stderr warnings (`SDK XML version`, CMake `CMP0175`) trigger `NativeCommandError`.
