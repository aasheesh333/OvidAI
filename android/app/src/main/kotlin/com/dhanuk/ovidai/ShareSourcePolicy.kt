package com.dhanuk.ovidai

import java.io.File

/**
 * Which local files may be handed to another app through the share sheet (M2).
 *
 * The share path comes from Dart (user actions and agent tools alike), so it
 * is untrusted: without a check, `shareFile("/data/data/<pkg>/shared_prefs/…")`
 * would copy app-private state into the outgoing cache and grant it away.
 * A source must be a regular file whose CANONICAL path (symlinks resolved)
 * lies inside one of the allowed roots, outside every denied root, and is not
 * a known credential file.
 */
object ShareSourcePolicy {
    /** Basenames never shared, wherever they live. */
    val deniedNames = setOf(
        ".ovid-git-credentials", ".git-credentials", ".netrc", ".npmrc", ".pypirc",
        "id_rsa", "id_ecdsa", "id_ed25519",
    )

    /** Null when [canonicalPath] may be shared, otherwise the refusal reason. */
    fun refusal(canonicalPath: String, allowedRoots: List<String>, deniedRoots: List<String>): String? {
        if (canonicalPath.isBlank() || !canonicalPath.startsWith("/")) return "File path is not absolute"
        if (File(canonicalPath).name in deniedNames) return "This file holds credentials and cannot be shared"
        if (deniedRoots.any { within(canonicalPath, it) }) return "App-private files cannot be shared"
        if (allowedRoots.none { within(canonicalPath, it) }) return "This location cannot be shared"
        return null
    }

    internal fun within(path: String, root: String): Boolean {
        val r = root.trimEnd('/')
        if (r.isEmpty()) return false
        return path == r || path.startsWith("$r/")
    }
}
