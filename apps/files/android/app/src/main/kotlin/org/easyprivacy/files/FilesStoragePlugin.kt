package org.easyprivacy.files

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import android.content.Context
import android.Manifest
import android.os.Build
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.net.Uri
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class FilesStoragePlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private lateinit var storage: MethodChannel
    private lateinit var documentsChannel: MethodChannel
    private lateinit var documents: FolderDocuments
    private lateinit var permissionChannel: MethodChannel
    private var notificationResult: MethodChannel.Result? = null
    private var pendingSave: MethodChannel.Result? = null
    private var pendingFile: File? = null
    @Volatile private var pendingPick: MethodChannel.Result? = null
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        documents = FolderDocuments(context) { activity }
        documentsChannel = MethodChannel(binding.binaryMessenger, "org.easyprivacy/files_documents")
        documentsChannel.setMethodCallHandler(documents::handle)
        permissionChannel = MethodChannel(binding.binaryMessenger, "org.easyprivacy/files_permission")
        permissionChannel.setMethodCallHandler { call, result ->
            if (call.method != "notifications") result.notImplemented()
            else if (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) result.success(true)
            else if (activity == null || notificationResult != null) result.error("busy", "Open Files to allow notifications.", null)
            else {
                notificationResult = result
                activity!!.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7316)
            }
        }
        storage = MethodChannel(binding.binaryMessenger, "org.easyprivacy/files_storage")
        storage
            .setMethodCallHandler { call, result ->
                if (call.method == "syncEnginePath") {
                    result.success(File(context.applicationInfo.nativeLibraryDir, "libeasyprivacy_sync_engine.so").absolutePath)
                    return@setMethodCallHandler
                }
                if (call.method == "pickFile") {
                    if (pendingPick != null) {
                        result.error("busy", "Finish the current file selection first.", null)
                        return@setMethodCallHandler
                    }
                    pendingPick = result
                    try {
                        activity!!.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }, 7313)
                    } catch (_: Exception) {
                        pendingPick = null
                        result.error("pick_failed", "Could not open the file picker.", null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "saveReceived") { result.notImplemented(); return@setMethodCallHandler }
                if (pendingSave != null) { result.error("busy", "Finish the current save dialog first.", null); return@setMethodCallHandler }
                try {
                    val root = File(context.filesDir, "easyprivacy-send").canonicalFile
                    val file = File(call.argument<String>("path") ?: "").canonicalFile
                    val name = call.argument<String>("name") ?: "file"
                    val syncRoot = File(context.filesDir, "easyprivacy-sync").canonicalFile
                    val syncRelative = file.path.removePrefix(syncRoot.path + File.separator)
                    val syncFile = file.path.startsWith(syncRoot.path + File.separator) &&
                        Regex("^[0-9a-f]{64}/folders/ep-[0-9a-f]{32}/.+").matches(syncRelative)
                    val driveRoot = File(context.filesDir, "easyprivacy-drive").canonicalFile
                    val driveRelative = file.path.removePrefix(driveRoot.path + File.separator)
                    val driveFile = file.path.startsWith(driveRoot.path + File.separator) &&
                        Regex("^[0-9a-f]{32}/payload$").matches(driveRelative)
                    require(((file.path.startsWith(root.path + File.separator) && file.name == "payload.received") || syncFile || driveFile) && file.isFile)
                    require(name.isNotEmpty() && name.length <= 180 && !name.contains('/') && !name.contains('\\'))
                    pendingSave = result
                    pendingFile = file
                    activity!!.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }, 7312)
                } catch (_: Exception) {
                    pendingSave = null; pendingFile = null
                    result.error("save_failed", "Could not open the save dialog.", null)
                }
            }
    }
    @Deprecated("Used by the document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (documents.onActivityResult(requestCode, resultCode, data)) return true
        if (requestCode != 7312 && requestCode != 7313) return false
        handleActivityResult(requestCode, resultCode, data)
        return true
    }
    private fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 7313) {
            val result = pendingPick ?: return
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                pendingPick = null
                result.success(null)
            } else {
                prepareSelectedFile(uri, result)
            }
            return
        }
        if (requestCode != 7312) return
        val result = pendingSave ?: return
        val file = pendingFile
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) {
            pendingSave = null; pendingFile = null; result.success(false); return
        }
        // The OS creates a new document selected by the owner. Copy with a fixed
        // buffer, never a whole-file byte array or broad storage permission.
        Thread {
            var success = false
            try {
                context.contentResolver.openOutputStream(uri, "w")!!.use { output ->
                    file.inputStream().use { input -> input.copyTo(output, 64 * 1024) }
                    output.flush()
                }
                success = true
            } catch (_: Exception) {
                try { DocumentsContract.deleteDocument(context.contentResolver, uri) } catch (_: Exception) { }
            }
            Handler(Looper.getMainLooper()).post {
                pendingSave = null; pendingFile = null
                if (success) result.success(true) else result.error("save_failed", "Could not save the file. Your received copy is still available.", null)
            }
        }.start()
    }

    private fun prepareSelectedFile(uri: Uri, result: MethodChannel.Result) {
        Thread {
            var directory: File? = null
            var prepared: Map<String, String>? = null
            try {
                val root = File(context.cacheDir, "easyprivacy-sources").canonicalFile
                require(root.parentFile == context.cacheDir.canonicalFile)
                root.mkdirs()
                // Expire only our own UUID cache directories; originals are never removed.
                val retained = root.listFiles()?.filter {
                    it.isDirectory && it.name.matches(Regex("^[0-9a-f-]{36}$")) &&
                        it.canonicalFile.parentFile == root
                }?.sortedByDescending { it.lastModified() } ?: emptyList()
                retained.forEachIndexed { index, entry ->
                    if (index >= 7 || System.currentTimeMillis() - entry.lastModified() > 24 * 60 * 60 * 1000L) {
                        entry.deleteRecursively()
                    }
                }
                require(root.usableSpace >= 128L * 1024 * 1024)
                var name = "file"
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (column >= 0 && cursor.moveToFirst()) name = cursor.getString(column) ?: name
                }
                val staging = File(root, UUID.randomUUID().toString())
                directory = staging
                require(staging.mkdirs())
                val temporary = File(staging, "payload.partial")
                var total = 0L
                context.contentResolver.openInputStream(uri)!!.use { input ->
                    FileOutputStream(temporary).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            check(pendingPick === result)
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (count == 0) continue
                            total += count
                            require(total <= (1L shl 40))
                            if (total % (64L * 1024 * 1024) < count) {
                                require(root.usableSpace >= 128L * 1024 * 1024)
                            }
                            output.write(buffer, 0, count)
                        }
                        output.flush()
                        output.fd.sync()
                    }
                }
                val payload = File(staging, "payload")
                require(temporary.renameTo(payload))
                prepared = mapOf("path" to payload.path, "name" to name.ifBlank { "file" }.take(180))
            } catch (_: Exception) {
                directory?.deleteRecursively()
            }
            Handler(Looper.getMainLooper()).post {
                if (pendingPick !== result) {
                    directory?.deleteRecursively()
                    return@post
                }
                pendingPick = null
                if (prepared != null) result.success(prepared)
                else result.error("pick_failed", "Could not prepare this file. Check storage and choose it again.", null)
            }
        }.start()
    }

    private fun cancelPick() {
        val result = pendingPick
        pendingPick = null
        result?.error("cancelled", "File selection closed.", null)
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        cancelPick()
        notificationResult?.success(false)
        notificationResult = null
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        storage.setMethodCallHandler(null)
        documentsChannel.setMethodCallHandler(null)
        permissionChannel.setMethodCallHandler(null)
        cancelPick()
    }
    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray): Boolean {
        if (code != 7316) return false
        notificationResult?.success(results.isNotEmpty() && results[0] == PackageManager.PERMISSION_GRANTED)
        notificationResult = null
        return true
    }

}
