package org.easyprivacy.easyprivacy

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

class VpnForegroundService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var stopped = false
    private val refresh = object : Runnable {
        override fun run() {
            VpnRuntime.executor.execute {
                try {
                    val state = VpnRuntime.status()
                    if (!stopped) {
                        VpnNotifications.publish(this@VpnForegroundService, state)
                        if (state["active"] != true) stopSelf()
                    }
                } catch (_: Exception) {
                    if (!stopped) VpnNotifications.publish(this@VpnForegroundService,
                        mapOf("active" to true), "VPN status unavailable")
                }
            }
            handler.postDelayed(this, 3000)
        }
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        VpnRuntime.initialize(this)
        VpnNotifications.createChannel(this)
        val notification = VpnNotifications.build(this, active = true)
        if (Build.VERSION.SDK_INT >= 34) startForeground(VpnNotifications.ID, notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        else startForeground(VpnNotifications.ID, notification)
        handler.post(refresh)
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "disconnect") VpnRuntime.executor.execute {
            try { VpnRuntime.disconnect() }
            catch (_: Exception) {
                // Keep Disconnect available if the tunnel could not be stopped.
                VpnNotifications.publish(this, mapOf("active" to true))
            }
        }
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        stopped = true
        handler.removeCallbacks(refresh)
        stopForeground(STOP_FOREGROUND_REMOVE)
        // Disconnected mode uses a regular notification, not an idle service.
        VpnRuntime.executor.execute {
            try { VpnNotifications.publish(this, VpnRuntime.status()) }
            catch (_: Exception) {
                VpnNotifications.publish(this, mapOf("active" to true), "VPN status unavailable")
            }
        }
        super.onDestroy()
    }
}
