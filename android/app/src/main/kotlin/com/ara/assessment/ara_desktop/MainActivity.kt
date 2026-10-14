package com.ara.assessment.ara_desktop

import android.content.ActivityNotFoundException
import android.content.Intent
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "ara_desktop/mobile_kiosk"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setFlagSecure" -> {
                    val enable = call.argument<Boolean>("enabled") ?: false
                    runOnUiThread {
                        if (enable) {
                            window.setFlags(
                                WindowManager.LayoutParams.FLAG_SECURE,
                                WindowManager.LayoutParams.FLAG_SECURE
                            )
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
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
                startActivity(intent)
                return "opened"
            } catch (e: ActivityNotFoundException) {
                // Try the next candidate
            }
        }
        return "no_app"
    }
}
