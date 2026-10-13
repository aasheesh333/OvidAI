package com.dhanuk.ovidai

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Owns the single Dart runtime ("ovid-background" in FlutterEngineCache).
 *
 * While the UI is open MainActivity creates/attaches it; after the UI closes
 * the engine is retained. When the process was killed (swipe + OEM kill,
 * reboot, update) the foreground service or an alarm calls [ensure], which
 * boots the same app entrypoint headlessly. MainActivity later reuses that
 * engine through provideFlutterEngine, so there is never a second runtime.
 */
object OvidEngineHost {
    const val ENGINE_ID = "ovid-background"

    /** Test seam: Robolectric cannot load libflutter.so. */
    @Volatile
    var factoryForTest: ((Context) -> Boolean)? = null

    fun isAlive(): Boolean = FlutterEngineCache.getInstance().get(ENGINE_ID) != null

    /** Must run on the main thread. Returns false when the runtime cannot start. */
    fun ensure(context: Context): Boolean {
        val app = context.applicationContext
        factoryForTest?.let { return it(app) }
        if (isAlive()) return true
        return try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(app)
            loader.ensureInitializationComplete(app, null)
            // automaticallyRegisterPlugins defaults to true: plugins needing
            // an Activity attach later, when MainActivity adopts this engine.
            val engine = FlutterEngine(app)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "main"),
            )
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            BackgroundChannel.attachHeadless(app, engine)
            true
        } catch (e: Throwable) {
            BackgroundScheduleState.constraint(app, "Background runtime could not start: ${e.message}")
            false
        }
    }
}
