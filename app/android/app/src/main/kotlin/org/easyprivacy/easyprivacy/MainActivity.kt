package org.easyprivacy.easyprivacy

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.net.VpnService
import android.app.Activity

class MainActivity : FlutterActivity() {
    private var pending: Pair<Map<*, *>, MethodChannel.Result>? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        VpnRuntime.initialize(applicationContext)
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.easyprivacy/vpn").setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> result.success(mapOf("installed" to true))
                "status" -> work(result) { VpnRuntime.status() }
                "disconnect" -> work(result) { VpnRuntime.disconnect(); VpnRuntime.status() }
                "connect" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null || pending != null) result.error("vpn_busy", "Another VPN action is in progress.", null)
                    else {
                        val permission = VpnService.prepare(this)
                        if (permission != null) { pending = Pair(args, result); startActivityForResult(permission, 1040) }
                        else connect(args, result)
                    }
                }
                else -> result.notImplemented()
            }
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
