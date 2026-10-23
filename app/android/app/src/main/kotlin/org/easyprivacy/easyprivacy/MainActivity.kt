package org.easyprivacy.easyprivacy

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.net.VpnService
import android.app.Activity
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings

class MainActivity : FlutterActivity() {
    private var pending: Pair<Map<*, *>, MethodChannel.Result>? = null
    private var presence: MethodChannel? = null
    private var notificationPermission: ((Boolean) -> Unit)? = null
    private var connectRequested = false
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        VpnRuntime.initialize(applicationContext)
        VpnNotifications.createChannel(this)
        connectRequested = intent?.action == VpnNotifications.CONNECT
        if (connectRequested) intent.action = null
        presence = MethodChannel(engine.dartExecutor.binaryMessenger, "org.easyprivacy/presence").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "pendingAction" -> {
                        result.success(if (connectRequested) "connect" else null)
                        connectRequested = false
                    }
                    "requestPermission" -> requestNotifications { result.success(it) }
                    "openSettings" -> {
                        startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                        result.success(null)
                    }
                    "update" -> {
                        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                        VpnNotifications.configure(this, args["alwaysShow"] == true)
                        VpnRuntime.executor.execute {
                            try {
                                val state = VpnRuntime.status()
                                val transient = if (args["visible"] == true && args["alwaysShow"] != true &&
                                    state["active"] != true) args["status"] as? String else null
                                VpnNotifications.publish(this, state, transient, args["actionEnabled"] == true)
                                runOnUiThread { result.success(VpnNotifications.enabled(this)) }
                            } catch (_: Exception) {
                                runOnUiThread { result.error("notification_failed", "Could not update VPN notification.", null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.easyprivacy/vpn").setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> result.success(mapOf("installed" to true))
                "status" -> work(result) { VpnRuntime.status() }
                "disconnect" -> work(result) { VpnRuntime.disconnect(); VpnRuntime.status() }
                "connect" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null || pending != null) result.error("vpn_busy", "Another VPN action is in progress.", null)
                    else {
                        pending = Pair(args, result)
                        requestNotifications {
                            val permission = VpnService.prepare(this)
                            if (permission != null) startActivityForResult(permission, 1040)
                            else { pending = null; connect(args, result) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == VpnNotifications.CONNECT) {
            intent.action = null
            connectRequested = true
            presence?.invokeMethod("connect", null, object : MethodChannel.Result {
                override fun success(result: Any?) { connectRequested = false }
                override fun error(code: String, message: String?, details: Any?) {}
                override fun notImplemented() {}
            })
        }
    }

    private fun requestNotifications(callback: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            callback(VpnNotifications.enabled(this))
        } else if (notificationPermission == null) {
            notificationPermission = callback
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1042)
        } else callback(false)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1042) {
            val callback = notificationPermission
            notificationPermission = null
            callback?.invoke(VpnNotifications.enabled(this))
        }
    }

    private fun work(result: MethodChannel.Result, action: () -> Map<String, Any>) {
        VpnRuntime.executor.execute {
            try { val value = action(); runOnUiThread { result.success(value) } }
            catch (_: Exception) { runOnUiThread { result.error("vpn_failed", "Android could not complete the VPN action. Check VPN permission and the core endpoint.", null) } }
        }
    }
    private fun connect(args: Map<*, *>, result: MethodChannel.Result) = work(result) { VpnRuntime.connect(args); VpnRuntime.status() }
    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 1040) return
        val request = pending ?: return
        pending = null
        if (resultCode == Activity.RESULT_OK) connect(request.first, request.second)
        else request.second.error("vpn_permission", "VPN permission was not granted.", null)
    }
}
