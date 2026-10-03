package com.dhanuk.ovidai

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.Before
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import android.webkit.MimeTypeMap
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class NativeShareTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    @Before fun prepareAndroidServices() {
        // Robolectric gives each test a new data directory. Attaching clears
        // AndroidX's static path cache from the previous application instance.
        FileProvider().attachInfo(context, context.packageManager.resolveContentProvider("${context.packageName}.fileprovider", 0)!!)
        // Its MIME shadow starts empty rather than loading Android's table.
        shadowOf(MimeTypeMap.getSingleton()).addExtensionMimeTypeMapping("png", "image/png")
    }

    @Test fun `image outside provider roots is copied and granted as content URI`() {
        val source = File.createTempFile("my image", ".PNG")
        try {
            source.writeBytes(byteArrayOf(1, 2, 3))
            val intent = NativeShare.fileIntent(context, source.path)
            assertEquals(Intent.ACTION_SEND, intent.action)
            assertEquals("image/png", intent.type)
            val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)!!
            assertEquals("content", uri.scheme)
            assertEquals("${context.packageName}.fileprovider", uri.authority)
            assertEquals(uri, intent.clipData!!.getItemAt(0).uri)
            assertTrue(intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            assertEquals(0, intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            val provider = FileProvider()
            provider.attachInfo(context, context.packageManager.resolveContentProvider(uri.authority!!, 0)!!)
            provider.openFile(uri, "r").use { descriptor ->
                android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use {
                    assertArrayEquals(byteArrayOf(1, 2, 3), it.readBytes())
                }
            }
            val chooser = NativeShare.chooser(intent, "Share image")
            assertEquals(Intent.ACTION_CHOOSER, chooser.action)
            assertEquals(uri, chooser.clipData!!.getItemAt(0).uri)
            assertTrue(chooser.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        } finally { source.delete() }
    }

    @Test fun `transcript is a UTF-8 file with a readable grant`() {
        val intent = NativeShare.transcriptIntent(context, "日本語\nhello", "../chat.txt")
        assertEquals("text/plain", intent.type)
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)!!
        assertEquals("chat.txt", uri.lastPathSegment)
        val provider = FileProvider()
        provider.attachInfo(context, context.packageManager.resolveContentProvider(uri.authority!!, 0)!!)
        provider.openFile(uri, "r").use { descriptor ->
            android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use {
                assertEquals("日本語\nhello", it.readBytes().toString(Charsets.UTF_8))
            }
        }
    }

    @Test fun `plain app share uses text without file grants`() {
        val intent = NativeShare.textIntent("Ovid\nhttps://dhanuk.page.gd/ovid")
        assertEquals("text/plain", intent.type)
        assertEquals("Ovid\nhttps://dhanuk.page.gd/ovid", intent.getStringExtra(Intent.EXTRA_TEXT))
        assertNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        assertEquals(0, intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    @Test fun `directories and missing files cannot be shared`() {
        for (path in listOf(context.cacheDir.path, "${context.cacheDir}/missing-file")) {
            try {
                NativeShare.fileIntent(context, path)
                fail("Expected rejection for $path")
            } catch (_: java.io.IOException) { }
        }
    }
}
