package com.dhanuk.ovidai

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.PluginRegistry
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.lang.reflect.Proxy

/** Verifies the registry seam used by configureFlutterEngine without loading
 * FlutterJNI or changing any existing voice/channel registration. */
class StaticRichContentRegistrationTest {
    @Test fun `static renderer is added to the existing plugin registry`() {
        val added = mutableListOf<FlutterPlugin>()
        val registry = Proxy.newProxyInstance(
            PluginRegistry::class.java.classLoader,
            arrayOf(PluginRegistry::class.java),
        ) { _, method, args ->
            if (method.name == "add") {
                for (plugin in args.orEmpty()) {
                    if (plugin is FlutterPlugin) added.add(plugin)
                }
            }
            null
        } as PluginRegistry

        registerStaticRichContentRenderer(registry)

        assertEquals(1, added.size)
        assertEquals(StaticRichContentRenderer::class.java, added.single().javaClass)
    }

    @Test fun `configureFlutterEngine registers static renderer through helper once`() {
        val source = listOf(
            File("src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt"),
            File("app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt"),
        ).first { it.isFile }.readText()
        val configure = Regex(
            "override fun configureFlutterEngine[\\s\\S]*?\\n    }",
        ).find(source)?.value ?: error("configureFlutterEngine is missing")
        val registration = "registerStaticRichContentRenderer(flutterEngine.plugins)"

        assertEquals(1, Regex(Regex.escape(registration)).findAll(configure).count())
    }
}
