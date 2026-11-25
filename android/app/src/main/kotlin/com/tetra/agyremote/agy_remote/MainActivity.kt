package com.tetra.agyremote.agy_remote

import android.Manifest
import android.app.Activity
import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "com.tetra.agyremote/android_native"
        private const val ALERT_CHANNEL_ID = "agy_alerts"
        private const val REQ_CAPTURE_PHOTO = 4101
        private const val REQ_NOTIF_PERMISSION = 4102
        private const val MAX_SHARED_BYTES = 50L * 1024L * 1024L
        private const val CACHE_TTL_MS = 24L * 60L * 60L * 1000L
    }

    private var methodChannel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingShares = mutableListOf<Map<String, Any?>>()
    private var dartReadyToReceiveShares = false

    private var pendingPhotoResult: MethodChannel.Result? = null
    private var pendingPhotoFile: File? = null
    private var pendingNotifPermResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingShares" -> {
                    dartReadyToReceiveShares = true
                    val copy = synchronized(pendingShares) {
                        val list = pendingShares.toList()
                        pendingShares.clear()
                        list
                    }
                    result.success(copy)
                }

                "capturePhoto" -> startCameraCapture(result)

                "getDownloadsDir" -> {
                    val dir = File(cacheDir, "downloads").apply { mkdirs() }
                    pruneOldFiles(dir)
                    result.success(dir.absolutePath)
                }

                "openLocalFile" -> {
                    val path = call.argument<String>("path") ?: ""
                    val mime = call.argument<String>("mimeType") ?: "*/*"
                    result.success(openLocalFileWithIntent(path, mime))
                }

                "openRemoteMedia" -> {
                    val url = call.argument<String>("url") ?: ""
                    val mime = call.argument<String>("mimeType") ?: "*/*"
                    result.success(openRemoteMediaWithIntent(url, mime))
                }

                "shareLocalFile" -> {
                    val path = call.argument<String>("path") ?: ""
                    val mime = call.argument<String>("mimeType") ?: "*/*"
                    val title = call.argument<String>("title") ?: "分享文件"
                    result.success(shareLocalFileWithIntent(path, mime, title))
                }

                "enqueueSystemDownload" -> {
                    val url = call.argument<String>("url") ?: ""
                    val filename = call.argument<String>("filename") ?: "download.bin"
                    val mime = call.argument<String>("mimeType") ?: "*/*"
                    result.success(enqueueSystemDownload(url, filename, mime))
                }

                "requestNotificationPermission" -> handleRequestNotificationPermission(result)

                "updateRunningNotification" -> {
                    val title = call.argument<String>("title") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    startOrUpdateRunningService(title, body)
                    result.success(null)
                }

                "stopRunningNotification" -> {
                    stopRunningService()
                    result.success(null)
                }

                "showAlertNotification" -> {
                    val title = call.argument<String>("title") ?: "AGY Remote 通知"
                    val body = call.argument<String>("body") ?: ""
                    val id = call.argument<Int>("id") ?: 2001
                    postAlertNotification(title, body, id)
                    result.success(null)
                }

                "getAppVersion" -> {
                    result.success(readCurrentAppVersion())
                }

                "installApk" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(installApkFromPath(path))
                }

                else -> result.notImplemented()
            }
        }
        methodChannel = channel
    }

    private fun fileProviderAuthority(): String = "$packageName.fileprovider"

    private fun startCameraCapture(result: MethodChannel.Result) {
        if (pendingPhotoResult != null) {
            result.error("BUSY", "相机正在等待拍照结果", null)
            return
        }
        try {
            val camDir = File(cacheDir, "camera").apply { mkdirs() }
            pruneOldFiles(camDir)
            val file = File(camDir, "photo_${System.currentTimeMillis()}.jpg")
            val uri = FileProvider.getUriForFile(this, fileProviderAuthority(), file)
            val captureIntent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, uri)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            if (captureIntent.resolveActivity(packageManager) == null) {
                result.success(null)
                return
            }
            pendingPhotoResult = result
            pendingPhotoFile = file
            @Suppress("DEPRECATION")
            startActivityForResult(captureIntent, REQ_CAPTURE_PHOTO)
        } catch (e: Exception) {
            pendingPhotoResult = null
            pendingPhotoFile = null
            result.error("CAMERA_ERROR", e.message, null)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_CAPTURE_PHOTO) {
            val callback = pendingPhotoResult
            val file = pendingPhotoFile
            pendingPhotoResult = null
            pendingPhotoFile = null
            if (callback == null) return
            if (resultCode == Activity.RESULT_OK && file != null && file.exists() && file.length() > 0) {
                callback.success(
                    mapOf(
                        "path" to file.absolutePath,
                        "name" to file.name
                    )
                )
            } else {
                file?.delete()
                callback.success(null)
            }
        }
    }

    private fun handleRequestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        if (pendingNotifPermResult != null) {
            result.success(false)
            return
        }
        pendingNotifPermResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQ_NOTIF_PERMISSION
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIF_PERMISSION) {
            val cb = pendingNotifPermResult
            pendingNotifPermResult = null
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            cb?.success(granted)
        }
    }

    private fun openLocalFileWithIntent(path: String, mimeType: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        return try {
            val uri = FileProvider.getUriForFile(this, fileProviderAuthority(), file)
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType.ifBlank { "*/*" })
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(viewIntent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun readCurrentAppVersion(): Map<String, Any?> {
        return try {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
            mapOf(
                "versionName" to (info.versionName ?: ""),
                "versionCode" to code,
            )
        } catch (_: Exception) {
            mapOf("versionName" to "", "versionCode" to 0L)
        }
    }

    private fun installApkFromPath(path: String): Map<String, Any?> {
        if (path.isBlank()) {
            return mapOf("ok" to false, "needsPermission" to false, "error" to "安装包路径为空")
        }
        val file = File(path)
        if (!file.exists()) {
            return mapOf("ok" to false, "needsPermission" to false, "error" to "安装包文件不存在")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            return try {
                val permIntent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(permIntent)
                mapOf(
                    "ok" to false,
                    "needsPermission" to true,
                    "error" to "请在系统设置中允许 AGY Remote 安装未知来源应用，然后再次点击安装",
                )
            } catch (e: Exception) {
                mapOf(
                    "ok" to false,
                    "needsPermission" to true,
                    "error" to (e.message ?: "无法打开未知应用安装权限设置"),
                )
            }
        }
        return try {
            val uri = FileProvider.getUriForFile(this, fileProviderAuthority(), file)
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(installIntent)
            mapOf("ok" to true, "needsPermission" to false)
        } catch (e: Exception) {
            mapOf("ok" to false, "needsPermission" to false, "error" to (e.message ?: "无法拉起系统安装器"))
        }
    }

    private fun openRemoteMediaWithIntent(url: String, mimeType: String): Boolean {
        if (url.isBlank()) return false
        return try {
            val uri = Uri.parse(url)
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType.ifBlank { "*/*" })
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(viewIntent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun shareLocalFileWithIntent(path: String, mimeType: String, title: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        return try {
            val uri = FileProvider.getUriForFile(this, fileProviderAuthority(), file)
            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType.ifBlank { "*/*" }
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(sendIntent, title).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(chooser)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun enqueueSystemDownload(
        url: String,
        filename: String,
        mimeType: String
    ): Map<String, Any?> {
        if (url.isBlank()) {
            return mapOf("ok" to false, "error" to "下载地址为空")
        }
        val cleanBase = filename
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .trim()
            .replace(Regex("[/\\\\:*?\"<>|]+"), "_")
        val safeName = cleanBase.ifBlank { "download.bin" }
        return try {
            val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            val request = DownloadManager.Request(Uri.parse(url)).apply {
                setTitle(safeName)
                setDescription("AGY Remote 安全下载")
                setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                setAllowedOverMetered(true)
                setAllowedOverRoaming(true)
                addRequestHeader(
                    "User-Agent",
                    "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
                )
                if (mimeType.isNotBlank() && mimeType != "*/*") {
                    setMimeType(mimeType)
                }
                try {
                    setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, safeName)
                } catch (_: Exception) {
                    setDestinationInExternalFilesDir(this@MainActivity, Environment.DIRECTORY_DOWNLOADS, safeName)
                }
            }
            val id = dm.enqueue(request)
            mapOf("ok" to true, "id" to id, "filename" to safeName)
        } catch (e: Exception) {
            mapOf("ok" to false, "error" to (e.message ?: "系统下载器启动失败"))
        }
    }

    private fun startOrUpdateRunningService(title: String, body: String) {
        try {
            val svcIntent = Intent(this, AgentStatusService::class.java).apply {
                action = AgentStatusService.ACTION_UPDATE
                putExtra(AgentStatusService.EXTRA_TITLE, title)
                putExtra(AgentStatusService.EXTRA_BODY, body)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(svcIntent)
            } else {
                startService(svcIntent)
            }
        } catch (_: Exception) {
        }
    }

    private fun stopRunningService() {
        try {
            stopService(Intent(this, AgentStatusService::class.java))
        } catch (_: Exception) {
        }
    }

    private fun postAlertNotification(title: String, body: String, id: Int) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (nm.getNotificationChannel(ALERT_CHANNEL_ID) == null) {
                    val channel = NotificationChannel(
                        ALERT_CHANNEL_ID,
                        "任务完成与确认提醒",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        description = "Agent 完成任务或发起人工确认时提醒"
                        enableVibration(true)
                    }
                    nm.createNotificationChannel(channel)
                }
            }
            val launchIntent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
            val pendingIntent = PendingIntent.getActivity(this, id, launchIntent, piFlags)

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, ALERT_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }

            val notification = builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .build()

            nm.notify(id, notification)
        } catch (_: Exception) {
        }
    }

    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return

        val sharedText = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val uris = LinkedHashSet<Uri>()

        if (action == Intent.ACTION_SEND) {
            val single = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }
            if (single != null) uris.add(single)
        } else {
            val multi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            if (multi != null) uris.addAll(multi)
        }

        val clip = intent.clipData
        if (uris.isEmpty() && clip != null) {
            for (i in 0 until clip.itemCount) {
                val itemUri = clip.getItemAt(i).uri
                if (itemUri != null) uris.add(itemUri)
            }
        }

        if (sharedText.isNullOrBlank() && uris.isEmpty()) return

        Thread {
            val sharedDir = File(cacheDir, "shared_in").apply { mkdirs() }
            pruneOldFiles(sharedDir)

            val copiedFiles = mutableListOf<Map<String, Any?>>()
            for (uri in uris) {
                copyUriToCache(uri, sharedDir)?.let { copiedFiles.add(it) }
            }

            if (sharedText.isNullOrBlank() && copiedFiles.isEmpty()) return@Thread

            val payload = mapOf<String, Any?>(
                "text" to sharedText,
                "files" to copiedFiles
            )
            mainHandler.post {
                val ch = methodChannel
                if (ch != null && dartReadyToReceiveShares) {
                    ch.invokeMethod("onShareReceived", payload)
                } else {
                    synchronized(pendingShares) {
                        pendingShares.add(payload)
                    }
                }
            }
        }.start()
    }

    private fun copyUriToCache(uri: Uri, targetDir: File): Map<String, Any?>? {
        return try {
            val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"
            val displayName = sanitizeFilename(resolveDisplayName(uri, mimeType))
            val outFile = File(targetDir, "${System.currentTimeMillis()}_$displayName")

            var totalBytes = 0L
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output ->
                    val buf = ByteArray(16 * 1024)
                    while (true) {
                        val read = input.read(buf)
                        if (read <= 0) break
                        totalBytes += read
                        if (totalBytes > MAX_SHARED_BYTES) {
                            outFile.delete()
                            return null
                        }
                        output.write(buf, 0, read)
                    }
                }
            } ?: return null

            if (totalBytes <= 0L) {
                outFile.delete()
                return null
            }

            mapOf(
                "path" to outFile.absolutePath,
                "name" to displayName,
                "mimeType" to mimeType
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun resolveDisplayName(uri: Uri, mimeType: String): String {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (idx >= 0) {
                            val name = cursor.getString(idx)
                            if (!name.isNullOrBlank()) return name
                        }
                    }
                }
        } catch (_: Exception) {
        }
        val segment = uri.lastPathSegment?.substringAfterLast('/')
        if (!segment.isNullOrBlank()) return segment
        val ext = when {
            mimeType.contains("png") -> "png"
            mimeType.contains("jpeg") || mimeType.contains("jpg") -> "jpg"
            mimeType.contains("pdf") -> "pdf"
            mimeType.contains("webp") -> "webp"
            else -> "bin"
        }
        return "shared_file.$ext"
    }

    private fun sanitizeFilename(raw: String): String {
        val base = raw.substringAfterLast('/').substringAfterLast('\\').trim()
        val safe = base.replace(Regex("[^a-zA-Z0-9._\\-\\u4e00-\\u9fff]+"), "_")
        return safe.ifBlank { "shared_file" }
    }

    private fun pruneOldFiles(dir: File) {
        val cutoff = System.currentTimeMillis() - CACHE_TTL_MS
        dir.listFiles()?.forEach { f ->
            if (f.isFile && f.lastModified() < cutoff) {
                f.delete()
            }
        }
    }
}
