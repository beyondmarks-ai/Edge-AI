package com.example.edge

import android.app.Activity
import android.app.ActivityManager
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val filePickerChannelName = "edge/file_picker"
    private val modelChannelName = "edge/model_downloader"
    private val preferencesName = "edge_model_downloader"
    private val downloadIdKey = "download_id"
    private val requestCodePickFile = 9017
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            filePickerChannelName
        ).setMethodCallHandler { call, result ->
            if (call.method == "pickFile") {
                pickFile(result)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            modelChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "modelStatus" -> {
                    val fileName = call.argument<String>("fileName") ?: "offline-model.gguf"
                    val expectedBytes = call.argument<Number>("expectedBytes")?.toLong() ?: 0L
                    result.success(modelStatus(fileName, expectedBytes))
                }
                "startModelDownload" -> {
                    val url = call.argument<String>("url")
                    val fileName = call.argument<String>("fileName") ?: "offline-model.gguf"

                    if (url.isNullOrBlank()) {
                        result.error("BAD_URL", "Model URL is missing.", null)
                    } else {
                        result.success(startModelDownload(url, fileName))
                    }
                }
                "resetModelDownload" -> {
                    val fileName = call.argument<String>("fileName") ?: "offline-model.gguf"
                    result.success(resetModelDownload(fileName))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun pickFile(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("PICKER_BUSY", "A file picker is already open.", null)
            return
        }

        pendingResult = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "text/plain",
                    "text/markdown",
                    "text/csv",
                    "application/csv",
                    "text/comma-separated-values",
                    "application/pdf"
                )
            )
        }

        startActivityForResult(intent, requestCodePickFile)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != requestCodePickFile) {
            return
        }

        val result = pendingResult
        pendingResult = null

        if (result == null) {
            return
        }

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }

        val uri = data.data as Uri

        try {
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            if (bytes == null) {
                result.error("READ_FAILED", "Could not read the selected file.", null)
                return
            }

            result.success(
                mapOf(
                    "name" to displayName(uri),
                    "bytes" to bytes
                )
            )
        } catch (error: Exception) {
            result.error("READ_FAILED", error.message, null)
        }
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (nameIndex >= 0 && cursor.moveToFirst()) {
                return cursor.getString(nameIndex)
            }
        }

        return uri.lastPathSegment ?: "uploaded-file"
    }

    private fun modelFile(fileName: String): File {
        val directory = File(getExternalFilesDir(null), "models")
        if (!directory.exists()) {
            directory.mkdirs()
        }

        return File(directory, fileName)
    }

    private fun modelStatus(fileName: String, expectedBytes: Long): Map<String, Any?> {
        val file = modelFile(fileName)
        val downloadedBytes = if (file.exists()) file.length() else 0L
        val complete = file.exists() && expectedBytes > 0 && downloadedBytes >= expectedBytes

        val active = queryActiveDownload()
        val activeDownloadInProgress = active.status == "running" ||
            active.status == "pending" ||
            active.status == "paused"
        val reportedDownloadedBytes = if (activeDownloadInProgress) {
            maxOf(downloadedBytes, active.downloadedBytes)
        } else {
            downloadedBytes
        }
        val reportedTotalBytes = if (activeDownloadInProgress && active.totalBytes > 0) {
            active.totalBytes
        } else {
            expectedBytes
        }
        val reportedStatus = when {
            complete -> "complete"
            activeDownloadInProgress -> active.status
            downloadedBytes > 0L && downloadedBytes < expectedBytes -> "incomplete"
            else -> "idle"
        }

        return mapOf(
            "exists" to complete,
            "path" to file.absolutePath,
            "absolutePath" to file.absolutePath,
            "fileExists" to file.exists(),
            "fileSize" to downloadedBytes,
            "downloadedBytes" to reportedDownloadedBytes,
            "totalBytes" to reportedTotalBytes,
            "status" to reportedStatus,
            "reason" to active.reason,
            "isEmulator" to isProbablyEmulator(),
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
            "availableMemoryBytes" to memoryInfo().availMem,
            "totalMemoryBytes" to memoryInfo().totalMem
        )
    }

    private fun memoryInfo(): ActivityManager.MemoryInfo {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(memoryInfo)
        return memoryInfo
    }

    private fun isProbablyEmulator(): Boolean {
        return Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.startsWith("unknown") ||
            Build.MODEL.contains("google_sdk", ignoreCase = true) ||
            Build.MODEL.contains("emulator", ignoreCase = true) ||
            Build.MODEL.contains("Android SDK built for x86", ignoreCase = true) ||
            Build.MANUFACTURER.contains("Genymotion", ignoreCase = true) ||
            Build.BRAND.startsWith("generic") && Build.DEVICE.startsWith("generic") ||
            Build.PRODUCT == "google_sdk"
    }

    private fun startModelDownload(url: String, fileName: String): Map<String, Any?> {
        val file = modelFile(fileName)
        if (file.exists()) {
            file.delete()
        }
        cleanupOldModels(fileName)

        val request = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle("Preparing offline AI")
            setDescription(fileName)
            setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
            )
            setAllowedOverMetered(true)
            setAllowedOverRoaming(false)
            setDestinationUri(Uri.fromFile(file))
        }
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val downloadId = manager.enqueue(request)
        saveDownloadId(downloadId)

        return modelStatus(fileName, 0)
    }

    private fun resetModelDownload(fileName: String): Map<String, Any?> {
        val downloadId = savedDownloadId()
        if (downloadId >= 0) {
            val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            manager.remove(downloadId)
        }

        getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .remove(downloadIdKey)
            .apply()

        val file = modelFile(fileName)
        if (file.exists()) {
            file.delete()
        }

        return modelStatus(fileName, 0)
    }

    private fun cleanupOldModels(activeFileName: String) {
        val directory = File(getExternalFilesDir(null), "models")
        directory.listFiles()?.forEach { candidate ->
            if (
                candidate.isFile &&
                candidate.name.endsWith(".gguf") &&
                candidate.name != activeFileName
            ) {
                candidate.delete()
            }
        }
    }

    private data class DownloadSnapshot(
        val downloadedBytes: Long,
        val totalBytes: Long,
        val status: String,
        val reason: Int
    )

    private fun queryActiveDownload(): DownloadSnapshot {
        val downloadId = savedDownloadId()
        if (downloadId < 0) {
            return DownloadSnapshot(0, 0, "idle", 0)
        }

        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val query = DownloadManager.Query().setFilterById(downloadId)
        manager.query(query)?.use { cursor ->
            if (!cursor.moveToFirst()) {
                return DownloadSnapshot(0, 0, "idle", 0)
            }

            val downloaded = cursor.longValue(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
            val total = cursor.longValue(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
            val statusCode = cursor.intValue(DownloadManager.COLUMN_STATUS)
            val reason = cursor.intValue(DownloadManager.COLUMN_REASON)
            val status = when (statusCode) {
                DownloadManager.STATUS_FAILED -> "failed"
                DownloadManager.STATUS_PAUSED -> "paused"
                DownloadManager.STATUS_PENDING -> "pending"
                DownloadManager.STATUS_RUNNING -> "running"
                DownloadManager.STATUS_SUCCESSFUL -> "complete"
                else -> "idle"
            }

            return DownloadSnapshot(downloaded, total, status, reason)
        }

        return DownloadSnapshot(0, 0, "idle", 0)
    }

    private fun savedDownloadId(): Long {
        return getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getLong(downloadIdKey, -1)
    }

    private fun saveDownloadId(downloadId: Long) {
        getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putLong(downloadIdKey, downloadId)
            .apply()
    }

    private fun android.database.Cursor.longValue(columnName: String): Long {
        val index = getColumnIndex(columnName)
        return if (index >= 0) getLong(index) else 0L
    }

    private fun android.database.Cursor.intValue(columnName: String): Int {
        val index = getColumnIndex(columnName)
        return if (index >= 0) getInt(index) else 0
    }
}
