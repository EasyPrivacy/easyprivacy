package org.easyprivacy.easyprivacy.broker

import android.app.Service
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.pm.PackageManager
import android.os.*
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/** Signature-protected control broker. File payloads never enter this channel. */
class CoreBrokerService : Service() {
    private class Operation(val message: Message, val capability: String) {
        var dispatched = false
        var responded = false
        var timeout: Runnable? = null
    }

    private val handler = Handler(Looper.getMainLooper())
    private val operations = mutableSetOf<Operation>()
    private val queued = mutableListOf<Operation>()
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var ready = false
    private val messenger = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            val packages = packageManager.getPackagesForUid(message.sendingUid)?.toSet() ?: emptySet()
            val trusted = packageManager.checkSignatures(
                android.os.Process.myUid(), message.sendingUid
            ) == PackageManager.SIGNATURE_MATCH
            val capability = when {
                "org.easyprivacy.easyprivacy" in packages -> "core"
                "org.easyprivacy.vpn" in packages -> "vpn"
                "org.easyprivacy.files" in packages -> "files"
                else -> null
            }
            if (!trusted || capability == null) {
                reply(message, null, "not_authorized", "This application cannot use Core.")
                return
            }
            if (message.what != 1 || message.replyTo == null) return
            if (message.data.getInt("protocol") != 1) {
                reply(message, null, "version_mismatch", "Update this application and Core together.")
                return
            }
            if (operations.size >= 16) {
                reply(message, null, "core_busy", "Core is handling too many requests. Try again.")
                return
            }
            val operation = Operation(Message.obtain(message), capability)
            operations.add(operation)
            operation.timeout = Runnable {
                if (!operation.responded) {
                    operation.responded = true
                    reply(operation.message, null, "core_timeout", "Core did not respond in time.")
                }
                // Dispatched Dart work cannot be cancelled here. Keep its slot
                // until completion so retries cannot create unlimited work.
                if (!operation.dispatched) {
                    queued.remove(operation)
                    operations.remove(operation)
                }
            }
            handler.postDelayed(operation.timeout!!, 20000)
            if (ready) dispatch(operation) else queued.add(operation)
        }
    })

    override fun onCreate() {
        super.onCreate()
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        engine = FlutterEngine(applicationContext)
        channel = MethodChannel(engine!!.dartExecutor.binaryMessenger, "org.easyprivacy/core_host")
        channel!!.setMethodCallHandler { call, result ->
            if (call.method == "ready") {
                ready = true
                result.success(null)
                val requests = queued.toList()
                queued.clear()
                requests.forEach(::dispatch)
            } else if (call.method == "nativeRuntimePath") {
                result.success(java.io.File(applicationInfo.nativeLibraryDir, "libeasyprivacy_core_runtime.so").absolutePath)
            } else if (call.method == "privateForeground") {
                val active = (call.arguments as? Map<*, *>)?.get("active") == true
                if (active) promotePrivate() else {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        engine!!.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "coreBrokerMain")
        )
    }

    override fun onBind(intent: Intent): IBinder = messenger.binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "org.easyprivacy.START_PRIVATE") promotePrivate()
        return START_NOT_STICKY
    }

    private fun promotePrivate() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel("easyprivacy-private", "Private connections", NotificationManager.IMPORTANCE_LOW)
        )
        val launch = Intent().setClassName(packageName, "$packageName.MainActivity")
        val pending = PendingIntent.getActivity(this, 41930, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "easyprivacy-private") else Notification.Builder(this)
        val notification = builder.setContentTitle("EasyPrivacy Core")
            .setContentText("Private connection enabled")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(pending).setOngoing(true).setCategory(Notification.CATEGORY_SERVICE).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(41930, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(41930, notification)
    }

    private fun dispatch(operation: Operation) {
        operation.dispatched = true
        try {
            val method = operation.message.data.getString("method") ?: error("missing method")
            val raw = operation.message.data.getString("arguments") ?: "{}"
            require(method.length <= 80 && raw.toByteArray(Charsets.UTF_8).size <= 16384)
            val arguments = json(JSONObject(raw))
            channel!!.invokeMethod(
                "rpc",
                mapOf("capability" to operation.capability, "method" to method, "arguments" to arguments),
                object : MethodChannel.Result {
                    override fun success(result: Any?) = complete(operation, result)
                    override fun error(code: String, details: String?, extra: Any?) =
                        complete(operation, null, code, details ?: "Core could not complete the operation.")
                    override fun notImplemented() =
                        complete(operation, null, "unsupported", "Update Core.")
                }
            )
        } catch (_: Exception) {
            complete(operation, null, "invalid_request", "Invalid Core operation.")
        }
    }

    private fun complete(operation: Operation, result: Any?, code: String? = null, error: String? = null) {
        operation.timeout?.let(handler::removeCallbacks)
        operations.remove(operation)
        if (operation.responded) return
        operation.responded = true
        reply(operation.message, result, code, error)
    }

    private fun reply(message: Message, result: Any?, code: String? = null, error: String? = null) {
        val response = Message.obtain(null, 1, message.arg1, 0)
        response.data = Bundle().apply {
            if (error != null) {
                putString("code", code?.take(80))
                putString("error", error.take(1024))
            } else {
                val encoded = JSONObject(result as? Map<*, *> ?: emptyMap<Any, Any>()).toString()
                if (encoded.toByteArray(Charsets.UTF_8).size > 16384) {
                    putString("code", "invalid_response")
                    putString("error", "Core response is too large.")
                } else {
                    putString("result", encoded)
                }
            }
        }
        try { message.replyTo?.send(response) } catch (_: RemoteException) {}
    }

    private fun json(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { json(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { json(value.get(it)) }
        else -> value
    }

    override fun onDestroy() {
        ready = false
        queued.clear()
        operations.toList().forEach {
            complete(it, null, "core_unavailable", "Core stopped.")
        }
        handler.removeCallbacksAndMessages(null)
        val oldEngine = engine
        engine = null
        var destroyed = false
        fun destroy() { if (!destroyed) { destroyed = true; oldEngine?.destroy() } }
        channel?.invokeMethod("shutdown", null, object : MethodChannel.Result {
            override fun success(result: Any?) = destroy()
            override fun error(code: String, message: String?, details: Any?) = destroy()
            override fun notImplemented() = destroy()
        })
        Handler(Looper.getMainLooper()).postDelayed({ destroy() }, 2500)
        super.onDestroy()
    }
}
