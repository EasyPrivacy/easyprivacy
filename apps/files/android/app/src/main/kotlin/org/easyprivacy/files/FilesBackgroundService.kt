package org.easyprivacy.files

import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/** Keeps the existing Files engine alive; no second replica or identity is created. */
class FilesBackgroundService : Service() {
    companion object {
        const val ENGINE = "easyprivacy-files"
        private var channel: MethodChannel? = null
        fun enabled(context: Context) = context.getSharedPreferences("files-background", Context.MODE_PRIVATE).getBoolean("active", false)
        fun attach(context: Context, engine: FlutterEngine) {
            channel = MethodChannel(engine.dartExecutor.binaryMessenger, "org.easyprivacy/files_presence")
            channel!!.setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        val active = call.argument<Boolean>("active") == true
                        try {
                            if (active && Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                result.error("notification_required", "Allow Files notifications before enabling background Sync.", null)
                                return@setMethodCallHandler
                            }
                            context.getSharedPreferences("files-background", Context.MODE_PRIVATE).edit().putBoolean("active", active).commit()
                            val intent = Intent(context, FilesBackgroundService::class.java)
                            if (active) {
                                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
                            } else context.stopService(intent)
                            result.success(null)
                        } catch (_: Exception) {
                            context.getSharedPreferences("files-background", Context.MODE_PRIVATE).edit().putBoolean("active", false).commit()
                            result.error("background_unavailable", "Open Files to enable background Sync.", null)
                        }
                    }
                    "requestPermission" -> {
                        // The attached Activity requests the notification permission.
                        result.success(Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        fun closeSession(engine: FlutterEngine) {
            channel?.invokeMethod("hostClosing", null, object : MethodChannel.Result {
                private fun close() {
                    if (FlutterEngineCache.getInstance().get(ENGINE) === engine) {
                        FlutterEngineCache.getInstance().remove(ENGINE)
                        engine.destroy()
                    }
                }
                override fun success(result: Any?) = close()
                override fun error(code: String, message: String?, details: Any?) = close()
                override fun notImplemented() = close()
            })
        }
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!enabled(this) || FlutterEngineCache.getInstance().get(ENGINE) == null) { stopSelf(); return START_NOT_STICKY }
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel("files-sync", "Folder synchronization", NotificationManager.IMPORTANCE_LOW))
        val launch = PendingIntent.getActivity(this, 7315, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "files-sync") else Notification.Builder(this)
        val notification = builder.setContentTitle("EasyPrivacy Files")
            .setContentText("Keeping your devices' folders in sync")
            .setSmallIcon(android.R.drawable.stat_notify_sync).setContentIntent(launch)
            .setOngoing(true).setCategory(Notification.CATEGORY_SERVICE).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(7315, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(7315, notification)
        return START_NOT_STICKY
    }
}
