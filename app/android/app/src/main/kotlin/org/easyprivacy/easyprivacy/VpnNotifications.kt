package org.easyprivacy.easyprivacy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build

/** Native notification state survives a closed Flutter UI. */
object VpnNotifications {
    const val ID = 1041
    const val CHANNEL = "easyprivacy-vpn"
    const val CONNECT = "org.easyprivacy.easyprivacy.CONNECT_VPN"
    private const val PREFS = "vpn-notifications"
    private var notificationLogo: Bitmap? = null

    private fun logo(context: Context): Bitmap? {
        notificationLogo?.let { return it }
        val drawable = context.getDrawable(R.mipmap.ic_launcher) ?: return null
        val size = (64 * context.resources.displayMetrics.density).toInt().coerceAtLeast(1)
        return Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also {
            drawable.setBounds(0, 0, size, size)
            drawable.draw(Canvas(it))
            notificationLogo = it
        }
    }

    fun alwaysShow(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("alwaysShow", false)

    fun configure(context: Context, alwaysShow: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("alwaysShow", alwaysShow).apply()
    }

    fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= 26) {
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "VPN connection", NotificationManager.IMPORTANCE_LOW))
        }
    }

    fun enabled(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
        return manager.areNotificationsEnabled() && (Build.VERSION.SDK_INT < 26 ||
            manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)
    }

    fun build(context: Context, active: Boolean, connected: Boolean = false,
              status: String? = null, canConnect: Boolean = true): Notification {
        createChannel(context)
        fun openIntent() = Intent(context, MainActivity::class.java).addFlags(
            Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val immutable = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val open = PendingIntent.getActivity(context, 1, openIntent(), immutable)
        val action = if (active) {
            PendingIntent.getService(context, 2,
                Intent(context, VpnForegroundService::class.java).setAction("disconnect"), immutable)
        } else {
            // Open the Activity before restoring pairing and requesting VPN consent.
            PendingIntent.getActivity(context, 3, openIntent().setAction(CONNECT), immutable)
        }
        val text = if (active) {
            status ?: if (connected) "VPN connected" else "Waiting for VPN server"
        } else status ?: "VPN disconnected"
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL)
            else Notification.Builder(context)
        builder.setContentTitle("EasyPrivacy VPN").setContentText(text)
            .setSmallIcon(R.drawable.ic_vpn_status).setContentIntent(open)
            .setLargeIcon(logo(context))
            .setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
        if (active || canConnect) {
            builder.addAction(Notification.Action.Builder(null,
                if (active) "Disconnect" else "Connect", action).build())
        }
        return builder.build()
    }

    fun publish(context: Context, state: Map<String, Any>, status: String? = null,
                canConnect: Boolean = true) {
        val active = state["active"] == true
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!active && !alwaysShow(context) && status == null) {
            manager.cancel(ID)
            return
        }
        val handshake = (state["last_handshake"] as? Number)?.toLong() ?: 0
        val connected = handshake > 0 && System.currentTimeMillis() / 1000 - handshake < 180
        manager.notify(ID, build(context, active, connected, status, canConnect))
    }
}
