package org.easyprivacy.files

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(FilesBackgroundService.ENGINE)
    override fun shouldDestroyEngineWithHost() = false
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        if (!engine.plugins.has(FilesStoragePlugin::class.java)) engine.plugins.add(FilesStoragePlugin())
        FlutterEngineCache.getInstance().put(FilesBackgroundService.ENGINE, engine)
        FilesBackgroundService.attach(applicationContext, engine)
    }
    override fun onDestroy() {
        val engine = flutterEngine
        val closing = !isChangingConfigurations && !FilesBackgroundService.enabled(applicationContext)
        super.onDestroy()
        if (closing && engine != null) FilesBackgroundService.closeSession(engine)
    }
}
