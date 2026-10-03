package com.dhanuk.ovidai

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException
import java.util.UUID

/** All outgoing files are snapshots in app cache, including external downloads.
 * Never hand another app a file:// URI or depend on it reading a private path.
 */
object NativeShare {
    private fun shareDirectory(context: Context): File {
        val root = File(context.cacheDir, "outgoing-shares")
        if (!root.exists() && !root.mkdirs()) throw IOException("Cannot create share cache")
        // Keep outstanding grants useful for a day; clean old snapshots on the
        // next share, never immediately after opening the chooser.
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        root.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.deleteRecursively() }
        return File(root, UUID.randomUUID().toString()).also {
            if (!it.mkdir()) throw IOException("Cannot create share directory")
        }
    }

    fun fileIntent(context: Context, path: String): Intent {
        val source = File(path)
        if (!source.isFile || !source.canRead()) throw IOException("File is unavailable")
        val target = File(shareDirectory(context), source.name)
        source.inputStream().use { input -> target.outputStream().use { input.copyTo(it) } }
        return streamIntent(context, target)
    }

    fun transcriptIntent(context: Context, text: String, fileName: String): Intent {
        val name = File(fileName).name.takeIf { it.isNotBlank() && it != "." && it != ".." }
            ?: "ovid-chat.txt"
        val target = File(shareDirectory(context), name)
        target.writeText(text, Charsets.UTF_8)
        return streamIntent(context, target, "text/plain")
    }

    private fun streamIntent(context: Context, file: File, mime: String? = null): Intent {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        return Intent(Intent.ACTION_SEND).apply {
            type = mime ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
                ?: "application/octet-stream"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri(file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    fun textIntent(text: String): Intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }

    fun chooser(payload: Intent, title: String): Intent = Intent.createChooser(payload, title).apply {
        if (payload.clipData != null) {
            clipData = payload.clipData
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }
}
