package org.easyprivacy.sdk

import android.content.*
import android.os.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class CoreSdkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private class Pending(val message: Message, val result: MethodChannel.Result, val timeout: Runnable)

    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val handler = Handler(Looper.getMainLooper())
    private val pending = mutableMapOf<Int, Pending>()
    private var nextId = 0
    private var remote: Messenger? = null
    private var binding = false
    private val replies = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            val item = pending.remove(message.arg1) ?: return
            handler.removeCallbacks(item.timeout)
            val error = message.data.getString("error")
            if (error != null) {
                item.result.error(message.data.getString("code") ?: "core_error", error, null)
                return
            }
            try {
                val raw = message.data.getString("result") ?: "{}"
                require(raw.toByteArray(Charsets.UTF_8).size <= 16384)
                item.result.success(json(JSONObject(raw)))
            } catch (_: Exception) {
                item.result.error("invalid_response", "Core returned an invalid response.", null)
            }
        }
    })
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            remote = Messenger(binder)
            pending.values.toList().forEach { send(it.message) }
        }
        override fun onServiceDisconnected(name: ComponentName) {
            remote = null
            failAll()
        }
        override fun onBindingDied(name: ComponentName) {
            detach()
            failAll()
        }
        override fun onNullBinding(name: ComponentName) {
            detach()
            failAll()
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "org.easyprivacy/core_broker")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "call") {
            result.notImplemented()
            return
        }
        if (pending.size >= 16) {
            result.error("core_busy", "Core is handling too many requests.", null)
            return
        }
        val args = call.arguments as? Map<*, *>
        val method = args?.get("method") as? String
        val body = args?.get("arguments") as? Map<*, *> ?: emptyMap<Any, Any>()
        if (method == null || method.length > 80) {
            result.error("invalid_request", "Invalid Core operation.", null)
            return
        }
        val encoded = try { JSONObject(body).toString() } catch (_: Exception) {
            result.error("invalid_request", "Invalid Core arguments.", null)
            return
        }
        if (encoded.toByteArray(Charsets.UTF_8).size > 16384) {
            result.error("invalid_request", "Core request is too large.", null)
            return
        }
        if (context.packageName == "org.easyprivacy.easyprivacy" && method == "privateStart") {
            try {
                val intent = Intent("org.easyprivacy.START_PRIVATE").setComponent(ComponentName(
                    "org.easyprivacy.easyprivacy", "org.easyprivacy.easyprivacy.broker.CoreBrokerService"
                ))
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            } catch (_: Exception) {
                result.error("foreground_required", "Open Core to start the private connection.", null)
                return
            }
        }
        nextId = if (nextId == Int.MAX_VALUE) 1 else nextId + 1
        val id = nextId
        val message = Message.obtain(null, 1, id, 0).apply {
            replyTo = replies
            data = Bundle().apply {
                putInt("protocol", 1)
                putString("method", method)
                putString("arguments", encoded)
            }
        }
        val timeout = Runnable {
            pending.remove(id)?.result?.error("core_timeout", "Core did not respond in time.", null)
        }
        pending[id] = Pending(message, result, timeout)
        handler.postDelayed(timeout, 20000)
        if (remote != null) {
            send(message)
        } else if (!binding) {
            try {
                binding = context.bindService(
                    Intent().setComponent(ComponentName(
                        "org.easyprivacy.easyprivacy",
                        "org.easyprivacy.easyprivacy.broker.CoreBrokerService"
                    )), connection, Context.BIND_AUTO_CREATE
                )
                if (!binding) failAll()
            } catch (_: Exception) {
                binding = false
                failAll()
            }
        }
    }

    private fun send(message: Message) {
        try { remote?.send(message) } catch (_: RemoteException) {
            detach()
            failAll()
        }
    }

    private fun failAll() {
        val items = pending.values.toList()
        pending.clear()
        items.forEach {
            handler.removeCallbacks(it.timeout)
            it.result.error("core_unavailable", "Install and open EasyPrivacy Core first.", null)
        }
    }

    private fun detach() {
        if (binding) try { context.unbindService(connection) } catch (_: Exception) {}
        binding = false
        remote = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        detach()
        failAll()
        handler.removeCallbacksAndMessages(null)
    }

    private fun json(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { json(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { json(value.get(it)) }
        else -> value
    }
}
