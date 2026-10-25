package org.easyprivacy.files

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract as Docs
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import org.json.JSONObject

/** All public storage access stays inside the owner's persisted Documents grant. */
class FolderDocuments(private val context: Context, private val activity: () -> Activity?) {
    private val resolver = context.contentResolver
    private val prefs = context.getSharedPreferences("files-documents", Context.MODE_PRIVATE)
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private data class Node(val uri: Uri, val name: String, val directory: Boolean, val size: Long = 0, val modified: Long = 0)
    private val hashes = mutableMapOf<String, Triple<Long, Long, String>>()
    companion object { const val REQUEST = 7314 }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "hasRoot") {
            try { root(); result.success(true) } catch (_: Exception) { result.success(false) }
            return
        }
        if (call.method == "chooseRoot") {
            val host = activity()
            if (host == null || pending != null) { result.error("busy", "Open Files to choose its Documents folder.", null); return }
            pending = result
            try {
                host.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                    putExtra(Docs.EXTRA_INITIAL_URI, Uri.parse("content://com.android.externalstorage.documents/document/primary%3ADocuments"))
                }, REQUEST)
            } catch (_: Exception) { pending = null; result.error("documents_unavailable", "Could not open the Documents folder picker.", null) }
            return
        }
        worker.execute {
            try {
                val key = call.argument<String>("key") ?: error("Missing folder")
                require(Regex("^[0-9a-f]{64}/ep-[0-9a-f]{32}$").matches(key))
                recover(key)
                val value: Any? = when (call.method) {
                    "prepare" -> prepare(key, call.argument<String>("label")!!, call.argument<String>("path")!!)
                    "snapshot" -> snapshot(folder(key))
                    "mkdir" -> { resolve(folder(key), relative(call), true); null }
                    "import" -> { importFile(key, call); null }
                    "export" -> { exportFile(key, call); null }
                    "delete" -> { delete(key, call); null }
                    "move" -> { move(key, call); null }
                    "open" -> {
                        val node = resolve(folder(key), relative(call), false) ?: error("Missing file")
                        require(!node.directory)
                        main.post {
                            try {
                                val host = activity() ?: error("Open Files first")
                                val edit = call.argument<Boolean>("edit") == true
                                host.startActivity(Intent.createChooser(Intent(if (edit) Intent.ACTION_EDIT else Intent.ACTION_VIEW).apply {
                                    setDataAndType(node.uri, mime(node.name))
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                                }, if (edit) "Edit with" else "Open with"))
                                result.success(null)
                            } catch (_: Exception) { result.error("open_failed", "No application could open this file.", null) }
                        }
                        return@execute
                    }
                    else -> { main.post { result.notImplemented() }; return@execute }
                }
                main.post { result.success(value) }
            } catch (_: Exception) {
                main.post { result.error("documents_unavailable", "Could not access the synced Documents folder. Check its permission, location, and available storage, then try again.", null) }
            }
        }
    }

    fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != REQUEST) return false
        val result = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(false); return true }
        try {
            require(uri.authority == "com.android.externalstorage.documents")
            val id = Docs.getTreeDocumentId(uri)
            require(id == "primary:Documents" || id == "primary:Documents/EasyPrivacy Files")
            val prior = prefs.getString("tree", null)
            require(prior == null || prior == uri.toString())
            resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            prefs.edit().putString("tree", uri.toString()).commit()
            result.success(true)
        } catch (_: Exception) { result.error("folder_required", "Choose Documents, or the existing Documents/EasyPrivacy Files folder.", null) }
        return true
    }

    private fun document(tree: Uri, id: String) = Docs.buildDocumentUriUsingTree(tree, id)
    private fun info(uri: Uri): Node {
        resolver.query(uri, arrayOf(Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE, Docs.Document.COLUMN_SIZE, Docs.Document.COLUMN_LAST_MODIFIED), null, null, null)!!.use {
            require(it.moveToFirst())
            return Node(uri, it.getString(0), it.getString(1) == Docs.Document.MIME_TYPE_DIR, it.getLong(2), it.getLong(3))
        }
    }
    private fun children(parent: Node): List<Node> {
        require(parent.directory)
        val result = mutableListOf<Node>()
        val uri = Docs.buildChildDocumentsUriUsingTree(parent.uri, Docs.getDocumentId(parent.uri))
        resolver.query(uri, arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE, Docs.Document.COLUMN_SIZE, Docs.Document.COLUMN_LAST_MODIFIED), null, null, null)!!.use {
            while (it.moveToNext()) result.add(Node(document(parent.uri, it.getString(0)), it.getString(1), it.getString(2) == Docs.Document.MIME_TYPE_DIR, it.getLong(3), it.getLong(4)))
        }
        return result
    }
    private fun child(parent: Node, name: String, create: Boolean): Node? {
        val found = children(parent).filter { it.name == name }
        require(found.size <= 1)
        if (found.isNotEmpty()) return found.single()
        return if (create) info(Docs.createDocument(resolver, parent.uri, Docs.Document.MIME_TYPE_DIR, name)!!) else null
    }
    private fun root(): Node {
        val tree = Uri.parse(prefs.getString("tree", null) ?: error("Choose Documents first"))
        require(resolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission && it.isWritePermission })
        val node = info(document(tree, Docs.getTreeDocumentId(tree)))
        return if (node.name == "EasyPrivacy Files") node else child(node, "EasyPrivacy Files", true)!!
    }
    private fun folder(key: String): Node {
        val saved = prefs.getString("folder:$key", null) ?: error("Folder is not attached")
        val parent = root() // Also verifies the persisted grant is still present.
        return children(parent).firstOrNull { it.uri.toString() == saved && it.directory } ?: error("Folder location is unavailable")
    }
    private fun localRoot(key: String): File = File(context.filesDir, "easyprivacy-sync/${key.substringBefore('/')}/folders/${key.substringAfter('/')}").canonicalFile
    private fun prepare(key: String, label: String, path: String): String {
        require(File(path).canonicalFile == localRoot(key))
        val saved = prefs.getString("folder:$key", null)
        val node = if (saved != null) folder(key) else {
            val parent = root()
            var name = label.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_").trim().trimEnd('.').take(80).ifBlank { "Shared folder" }
            // Never attach an unrelated existing public directory implicitly.
            if (children(parent).any { it.name.equals(name, true) }) name += " (${key.takeLast(8)})"
            require(children(parent).none { it.name.equals(name, true) })
            child(parent, name, true)!!.also {
                require(prefs.edit().putString("folder:$key", it.uri.toString()).commit())
            }
        }
        localRoot(key).mkdirs()
        return "Documents/EasyPrivacy Files/${node.name}"
    }
    private fun parts(value: String): List<String> {
        require(value.isNotEmpty() && value.length <= 2048)
        return value.split('/').also { pieces ->
            require(pieces.none { it.isEmpty() || it == "." || it == ".." || it.contains('\\') || it.contains(':') ||
                it.any { c -> c.code < 32 } || it.trim() != it || metadata(it) })
        }
    }
    private fun relative(call: MethodCall) = call.argument<String>("relative")!!.also { parts(it) }
    private fun resolve(parent: Node, path: String, create: Boolean): Node? {
        var current = parent
        for (part in parts(path)) current = child(current, part, create) ?: return null
        return current
    }
    private fun metadata(name: String) = name in setOf(".stfolder", ".stignore", ".stversions") ||
        name.startsWith(".syncthing.")
    private fun hash(node: Node, cached: Boolean = false): String {
        if (node.directory) return "directory"
        val previous = hashes[node.uri.toString()]
        if (cached && node.modified > 0 && previous?.first == node.size && previous.second == node.modified) return previous.third
        val value = resolver.openInputStream(node.uri)!!.use { input -> digest(input) }
        if (hashes.size >= 100000) hashes.clear()
        hashes[node.uri.toString()] = Triple(node.size, node.modified, value)
        return value
    }
    private fun digest(input: java.io.InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        while (true) { val n = input.read(buffer); if (n < 0) break; if (n > 0) digest.update(buffer, 0, n) }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    private fun snapshot(root: Node): Map<String, String> {
        val result = linkedMapOf<String, String>()
        fun visit(parent: Node, prefix: String) {
            for (node in children(parent)) {
                if (metadata(node.name)) continue
                val path = prefix + node.name
                parts(path)
                require(result.size < 100000)
                result[path] = hash(node, true)
                if (node.directory) visit(node, "$path/")
            }
        }
        visit(root, "")
        return result
    }
    private fun local(key: String, path: String): File {
        val root = localRoot(key)
        val file = File(path).canonicalFile
        require(file.path.startsWith(root.path + File.separator))
        return file
    }
    private fun importFile(key: String, call: MethodCall) {
        val node = resolve(folder(key), relative(call), false)!!
        require(!node.directory)
        val destination = local(key, call.argument<String>("destination")!!)
        val oldHash = call.argument<String>("oldHash")
        val temporary = File(destination.parentFile, ".syncthing.easyprivacy-${UUID.randomUUID()}.tmp")
        try {
            resolver.openInputStream(node.uri)!!.use { input -> FileOutputStream(temporary).use { output -> input.copyTo(output, 64 * 1024); output.fd.sync() } }
            require(temporary.inputStream().use { digest(it) } == call.argument<String>("hash"))
            require(if (destination.exists()) oldHash != null && destination.inputStream().use { digest(it) } == oldHash else oldHash == null)
            require(temporary.renameTo(destination))
        } finally { temporary.delete() }
    }
    private fun mime(name: String) = MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"
    private fun exportFile(key: String, call: MethodCall) {
        val path = relative(call)
        val pieces = parts(path)
        val parent = if (pieces.size == 1) folder(key) else resolve(folder(key), pieces.dropLast(1).joinToString("/"), true)!!
        val source = local(key, call.argument<String>("source")!!)
        require(source.isFile)
        val name = pieces.last()
        var temporary = info(Docs.createDocument(resolver, parent.uri, mime(name), ".syncthing.easyprivacy-write-${UUID.randomUUID()}.tmp")!!)
        val previousName = ".syncthing.easyprivacy-previous-${UUID.randomUUID()}"
        var previous: Node? = null
        val operation = JSONObject().put("parent", parent.uri.toString()).put("name", name)
            .put("temporary", temporary.name).put("previous", previousName).put("hash", call.argument<String>("hash"))
        require(prefs.edit().putString("pending:$key", operation.toString()).commit())
        try {
            resolver.openOutputStream(temporary.uri, "w")!!.use { output -> source.inputStream().use { it.copyTo(output, 64 * 1024) }; output.flush() }
            require(hash(temporary) == call.argument<String>("hash"))
            val existing = child(parent, name, false)
            val oldHash = call.argument<String>("oldHash")
            require(if (existing == null) oldHash == null else !existing.directory && oldHash != null && hash(existing) == oldHash)
            if (existing != null) previous = info(Docs.renameDocument(resolver, existing.uri, previousName)!!)
            temporary = info(Docs.renameDocument(resolver, temporary.uri, name)!!)
            previous?.let { require(Docs.deleteDocument(resolver, it.uri)) }
            previous = null
            prefs.edit().remove("pending:$key").commit()
        } catch (error: Exception) {
            try { Docs.deleteDocument(resolver, temporary.uri) } catch (_: Exception) { }
            previous?.let { try { Docs.renameDocument(resolver, it.uri, name) } catch (_: Exception) { } }
            recover(key)
            throw error
        }
    }
    private fun recover(key: String) {
        val text = prefs.getString("pending:$key", null) ?: return
        // Recover an interrupted document replacement before taking a snapshot.
        root()
        val operation = JSONObject(text)
        val parent = info(Uri.parse(operation.getString("parent")))
        val nodes = children(parent)
        val original = nodes.firstOrNull { it.name == operation.getString("name") }
        val previous = nodes.firstOrNull { it.name == operation.getString("previous") }
        val temporary = nodes.firstOrNull { it.name == operation.getString("temporary") }
        if (original == null) {
            if (previous != null) require(Docs.renameDocument(resolver, previous.uri, operation.getString("name")) != null)
            else if (temporary != null && hash(temporary) == operation.getString("hash")) {
                require(Docs.renameDocument(resolver, temporary.uri, operation.getString("name")) != null)
                prefs.edit().remove("pending:$key").commit()
                return
            } else {
                // An incomplete new export still has its engine-side source.
                temporary?.let { Docs.deleteDocument(resolver, it.uri) }
                prefs.edit().remove("pending:$key").commit()
                return
            }
        } else if (previous != null) {
            // Do not discard the retained old copy unless the new copy is verified.
            require(hash(original) == operation.getString("hash"))
            require(Docs.deleteDocument(resolver, previous.uri))
        }
        temporary?.let { Docs.deleteDocument(resolver, it.uri) }
        prefs.edit().remove("pending:$key").commit()
    }
    private fun delete(key: String, call: MethodCall) {
        val node = resolve(folder(key), relative(call), false) ?: return
        require(hash(node) == call.argument<String>("hash"))
        require(!node.directory || call.argument<Boolean>("recursive") == true || children(node).isEmpty())
        require(Docs.deleteDocument(resolver, node.uri))
    }
    private fun move(key: String, call: MethodCall) {
        val from = relative(call)
        val to = call.argument<String>("destination")!!.also { parts(it) }
        require(from != to && !to.startsWith("$from/"))
        val root = folder(key)
        val node = resolve(root, from, false)!!
        require(resolve(root, to, false) == null)
        val sourceParent = from.substringBeforeLast('/', "")
        val targetParent = to.substringBeforeLast('/', "")
        val a = if (sourceParent.isEmpty()) root else resolve(root, sourceParent, false)!!
        val b = if (targetParent.isEmpty()) root else resolve(root, targetParent, true)!!
        val moved = if (a.uri == b.uri) node.uri else Docs.moveDocument(resolver, node.uri, a.uri, b.uri)!!
        if (node.name != to.substringAfterLast('/')) require(Docs.renameDocument(resolver, moved, to.substringAfterLast('/')) != null)
    }
}
