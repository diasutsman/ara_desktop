package com.ara.assessment.ara_desktop

import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "ara_desktop/mobile_kiosk"

    private var methodChannel: MethodChannel? = null

    /** Always-On Kiosk Lockdown is enabled by default on Android from app launch. */
    private var isKioskLocked: Boolean = true
    private var isOfficeSessionActive: Boolean = false
    private var isPermissionRequestInProgress: Boolean = false
    private var isExitingCleanly: Boolean = false
    private var isActivityResumed: Boolean = false

    private val mainHandler = Handler(Looper.getMainLooper())
    private var backInvokedCallback: OnBackInvokedCallback? = null

    private val relaunchDelaysMs = longArrayOf(30L, 100L, 220L, 450L, 800L)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        registerPredictiveBackBlocker()
        applyKioskWindowFlags()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setFlagSecure" -> {
                    val enable = call.argument<Boolean>("enabled") ?: false
                    runOnUiThread {
                        setSecureFlag(enable)
                    }
                    result.success(true)
                }
                "setKioskLockdown" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    val requestPin = call.argument<Boolean>("lockTask") ?: false
                    runOnUiThread {
                        isKioskLocked = enabled
                        applyKioskWindowFlags()
                        if (enabled) {
                            engageLockTaskIfPermitted(forcePinPrompt = requestPin)
                        } else {
                            stopLockTaskSafely()
                        }
                    }
                    result.success(true)
                }
                "setOfficeSession" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    isOfficeSessionActive = active
                    if (active) {
                        mainHandler.removeCallbacksAndMessages(null)
                        stopLockTaskSafely()
                    }
                    result.success(true)
                }
                "setPermissionRequestInProgress" -> {
                    isPermissionRequestInProgress = call.argument<Boolean>("active") ?: false
                    result.success(true)
                }
                "exitApp" -> {
                    runOnUiThread {
                        isExitingCleanly = true
                        isKioskLocked = false
                        mainHandler.removeCallbacksAndMessages(null)
                        stopLockTaskSafely()
                        setSecureFlag(false)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            finishAndRemoveTask()
                        } else {
                            finish()
                        }
                    }
                    result.success(true)
                }
                "launchPackage" -> {
                    val packageName = call.argument<String>("package")
                    if (packageName != null) {
                        try {
                            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                            if (launchIntent != null) {
                                isOfficeSessionActive = true
                                stopLockTaskSafely()
                                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(launchIntent)
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        } catch (e: Exception) {
                            result.error("LAUNCH_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "Package name is null", null)
                    }
                }
                "isPackageInstalled" -> {
                    val packageName = call.argument<String>("package")
                    if (packageName != null) {
                        val isInstalled = try {
                            packageManager.getPackageInfo(packageName, 0)
                            true
                        } catch (e: Exception) {
                            false
                        }
                        result.success(isInstalled)
                    } else {
                        result.error("INVALID_ARGUMENT", "Package name is null", null)
                    }
                }
                "openDocument" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("INVALID_ARGUMENT", "Document path is null", null)
                    } else {
                        try {
                            result.success(
                                openDocument(
                                    File(path),
                                    call.argument<String>("mimeType") ?: "*/*",
                                    call.argument<List<String>>("packages") ?: emptyList()
                                )
                            )
                        } catch (e: Exception) {
                            result.error("OPEN_DOCUMENT_ERROR", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        isActivityResumed = true
        mainHandler.removeCallbacksAndMessages(null)
        applyKioskWindowFlags()
        if (isKioskLocked && !isOfficeSessionActive) {
            engageLockTaskIfPermitted(forcePinPrompt = false)
        }
    }

    override fun onPause() {
        isActivityResumed = false
        super.onPause()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (shouldBlockLeavingApp()) {
            notifyNavigationBlocked("minimize")
            seizeForegroundAggressively()
        }
    }

    override fun onStop() {
        super.onStop()
        if (shouldBlockLeavingApp()) {
            notifyNavigationBlocked("minimize")
            seizeForegroundAggressively()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && isKioskLocked) {
            applyImmersiveFullscreen()
        }
    }

    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean) {
        super.onMultiWindowModeChanged(isInMultiWindowMode)
        if (isInMultiWindowMode && isKioskLocked) {
            notifyNavigationBlocked("multi_window")
            seizeForegroundAggressively()
        }
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (isKioskLocked) {
            notifyNavigationBlocked("back")
            applyImmersiveFullscreen()
            return
        }
        super.onBackPressed()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (isKioskLocked) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_BACK -> {
                    if (event.action == KeyEvent.ACTION_DOWN) {
                        notifyNavigationBlocked("back")
                        applyImmersiveFullscreen()
                    }
                    return true
                }
                KeyEvent.KEYCODE_APP_SWITCH,
                KeyEvent.KEYCODE_MENU,
                KeyEvent.KEYCODE_HOME,
                KeyEvent.KEYCODE_SEARCH,
                KeyEvent.KEYCODE_ASSIST,
                KeyEvent.KEYCODE_VOICE_ASSIST -> {
                    if (event.action == KeyEvent.ACTION_DOWN) {
                        notifyNavigationBlocked("minimize")
                        applyImmersiveFullscreen()
                    }
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (isKioskLocked && (
                keyCode == KeyEvent.KEYCODE_BACK ||
                keyCode == KeyEvent.KEYCODE_APP_SWITCH ||
                keyCode == KeyEvent.KEYCODE_MENU ||
                keyCode == KeyEvent.KEYCODE_HOME ||
                keyCode == KeyEvent.KEYCODE_SEARCH ||
                keyCode == KeyEvent.KEYCODE_ASSIST
            )
        ) {
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onDestroy() {
        unregisterPredictiveBackBlocker()
        mainHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun shouldBlockLeavingApp(): Boolean {
        return isKioskLocked &&
            !isOfficeSessionActive &&
            !isPermissionRequestInProgress &&
            !isExitingCleanly
    }

    /**
     * Registers Android 13+ (API 33+) OnBackInvokedCallback with PRIORITY_OVERLAY so system
     * predictive back gestures are intercepted before they can pop or minimize the Activity.
     */
    private fun registerPredictiveBackBlocker() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (backInvokedCallback == null) {
                val callback = OnBackInvokedCallback {
                    if (isKioskLocked) {
                        notifyNavigationBlocked("back")
                        applyImmersiveFullscreen()
                    }
                }
                backInvokedCallback = callback
                onBackInvokedDispatcher.registerOnBackInvokedCallback(
                    OnBackInvokedDispatcher.PRIORITY_OVERLAY,
                    callback
                )
            }
        }
    }

    private fun unregisterPredictiveBackBlocker() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            backInvokedCallback?.let {
                try {
                    onBackInvokedDispatcher.unregisterOnBackInvokedCallback(it)
                } catch (_: Exception) {
                }
            }
            backInvokedCallback = null
        }
    }

    private fun applyKioskWindowFlags() {
        setSecureFlag(isKioskLocked)
        if (isKioskLocked) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            applyImmersiveFullscreen()
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            restoreNormalSystemUi()
        }
    }

    private fun setSecureFlag(enable: Boolean) {
        if (enable) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE
            )
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    @Suppress("DEPRECATION")
    private fun applyImmersiveFullscreen() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                window.setDecorFitsSystemWindows(false)
                window.insetsController?.let { controller ->
                    controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                    controller.systemBarsBehavior =
                        WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                }
            }
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                )
        } catch (_: Exception) {
        }
    }

    @Suppress("DEPRECATION")
    private fun restoreNormalSystemUi() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                window.insetsController?.show(
                    WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars()
                )
            }
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
        } catch (_: Exception) {
        }
    }

    /**
     * Immediately pulls MainActivity back to the foreground if the user attempts to press
     * Home (Minimize) or Recent Apps (Overview) without an active Office session.
     * Mirrors the Windows `ForceWindowToForeground` watchdog behavior.
     */
    private fun seizeForegroundAggressively() {
        bringTaskToFrontOnce()
        for (delay in relaunchDelaysMs) {
            mainHandler.postDelayed({
                if (!isActivityResumed && shouldBlockLeavingApp()) {
                    bringTaskToFrontOnce()
                }
            }, delay)
        }
    }

    private fun bringTaskToFrontOnce() {
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            am?.moveTaskToFront(taskId, ActivityManager.MOVE_TASK_WITH_HOME)
        } catch (_: Exception) {
        }

        try {
            val relaunchIntent = Intent(applicationContext, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK
                        or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                        or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        or Intent.FLAG_ACTIVITY_CLEAR_TOP
                        or Intent.FLAG_ACTIVITY_NO_ANIMATION
                )
            }
            startActivity(relaunchIntent)
        } catch (_: Exception) {
        }
    }

    /**
     * Engages Android OS LockTask mode automatically when permitted by DevicePolicyManager
     * (or when explicitly requested via forcePinPrompt).
     */
    private fun engageLockTaskIfPermitted(forcePinPrompt: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                if (am?.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE) {
                    return
                }
            }
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
            val isWhitelisted = dpm?.isLockTaskPermitted(packageName) == true
            if (isWhitelisted || forcePinPrompt) {
                startLockTask()
            }
        } catch (_: Exception) {
        }
    }

    private fun stopLockTaskSafely() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                if (am?.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE) {
                    stopLockTask()
                }
            } else {
                stopLockTask()
            }
        } catch (_: Exception) {
        }
    }

    private fun notifyNavigationBlocked(reason: String) {
        runOnUiThread {
            try {
                methodChannel?.invokeMethod("onNavigationBlocked", mapOf("reason" to reason))
            } catch (_: Exception) {
            }
        }
    }

    /**
     * Opens a downloaded document (inside cacheDir/ara_documents) through [AraDocumentFileProvider].
     * Prefers the given Office packages (e.g. Word, then the Microsoft 365 hub), then any viewer.
     * Returns "opened" or "no_app".
     */
    private fun openDocument(file: File, mimeType: String, packages: List<String>): String {
        if (!file.exists()) throw IllegalArgumentException("File not found: ${file.path}")

        val uri = FileProvider.getUriForFile(this, "$packageName.ara_documents", file)
        val baseIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        val candidates = packages.map { Intent(baseIntent).setPackage(it) } + baseIntent
        for (intent in candidates) {
            if (intent.resolveActivity(packageManager) == null) continue
            try {
                isOfficeSessionActive = true
                stopLockTaskSafely()
                startActivity(intent)
                return "opened"
            } catch (e: ActivityNotFoundException) {
                // Try the next candidate
            }
        }
        return "no_app"
    }
}
