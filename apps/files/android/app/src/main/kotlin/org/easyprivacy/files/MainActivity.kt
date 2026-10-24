package org.easyprivacy.files

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingSave: MethodChannel.Result? = null
    private var pendingFile: File? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.easyprivacy/files_storage")
            .setMethodCallHandler { call, result ->
                if (call.method == "syncEnginePath") {
                    result.success(File(applicationInfo.nativeLibraryDir, "libeasyprivacy_sync_engine.so").absolutePath)
                    return@setMethodCallHandler
                }
                if (call.method != "saveReceived") { result.notImplemented(); return@setMethodCallHandler }
                if (pendingSave != null) { result.error("busy", "Finish the current save dialog first.", null); return@setMethodCallHandler }
                try {
                    val root = File(filesDir, "easyprivacy-send").canonicalFile
                    val file = File(call.argument<String>("path") ?: "").canonicalFile
                    val name = call.argument<String>("name") ?: "file"
                    val syncRoot = File(filesDir, "easyprivacy-sync").canonicalFile
                    val syncRelative = file.path.removePrefix(syncRoot.path + File.separator)
                    val syncFile = file.path.startsWith(syncRoot.path + File.separator) &&
                        Regex("^[0-9a-f]{64}/folders/ep-[0-9a-f]{32}/.+").matches(syncRelative)
                    require(((file.path.startsWith(root.path + File.separator) && file.name == "payload.received") || syncFile) && file.isFile)
                    require(name.isNotEmpty() && name.length <= 180 && !name.contains('/') && !name.contains('\\'))
                    pendingSave = result
                    pendingFile = file
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
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
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
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
                contentResolver.openOutputStream(uri, "w")!!.use { output ->
                    file.inputStream().use { input -> input.copyTo(output, 64 * 1024) }
                    output.flush()
                }
                success = true
            } catch (_: Exception) {
                try { DocumentsContract.deleteDocument(contentResolver, uri) } catch (_: Exception) { }
            }
            Handler(Looper.getMainLooper()).post {
                pendingSave = null; pendingFile = null
                if (success) result.success(true) else result.error("save_failed", "Could not save the file. Your received copy is still available.", null)
            }
        }.start()
    }
}
