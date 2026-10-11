package com.dhanuk.ovidai

import org.junit.Assert.*
import org.junit.Test

class ShareSourcePolicyTest {
    private val allowed = listOf(
        "/data/user/0/com.dhanuk.ovidai/files",
        "/data/user/0/com.dhanuk.ovidai/cache",
        "/data/user/0/com.dhanuk.ovidai/app_flutter",
        "/storage/emulated/0",
    )
    private val denied = listOf(
        "/data/user/0/com.dhanuk.ovidai/shared_prefs",
        "/data/user/0/com.dhanuk.ovidai/databases",
        "/data/user/0/com.dhanuk.ovidai/no_backup",
        "/data/user/0/com.dhanuk.ovidai/files/datastore",
    )

    private fun refusal(path: String) = ShareSourcePolicy.refusal(path, allowed, denied)

    @Test fun `workspace, cache and shared storage files are shareable`() {
        for (path in listOf(
            "/data/user/0/com.dhanuk.ovidai/files/workspaces/s1/report.pdf",
            "/data/user/0/com.dhanuk.ovidai/cache/export/backup.json",
            "/data/user/0/com.dhanuk.ovidai/app_flutter/notes.md",
            "/storage/emulated/0/Download/photo.png",
        )) assertNull(path, refusal(path))
    }

    @Test fun `app-private state and outside paths are refused`() {
        for (path in listOf(
            "/data/user/0/com.dhanuk.ovidai/shared_prefs/FlutterSecureStorage.xml",
            "/data/user/0/com.dhanuk.ovidai/shared_prefs/FlutterSharedPreferences.xml",
            "/data/user/0/com.dhanuk.ovidai/databases/sessions.db",
            "/data/user/0/com.dhanuk.ovidai/files/datastore/x.preferences_pb",
            "/data/user/0/com.dhanuk.ovidai/no_backup/key",
            "/data/user/0/com.dhanuk.ovidai/lib/libapp.so",
            "/data/user/0/other.app/files/secret",
            "/proc/self/environ",
            "/etc/hosts",
            "relative/path.txt",
            "",
        )) assertNotNull(path, refusal(path))
    }

    @Test fun `credential files are refused even inside allowed roots`() {
        for (name in ShareSourcePolicy.deniedNames) {
            assertNotNull(name, refusal("/data/user/0/com.dhanuk.ovidai/files/usr/$name"))
        }
    }

    @Test fun `prefix siblings are not treated as inside a root`() {
        assertNotNull(refusal("/data/user/0/com.dhanuk.ovidai/files-evil/x"))
        assertNotNull(refusal("/storage/emulated/01/x"))
        assertTrue(ShareSourcePolicy.within("/a/b", "/a/b"))
        assertTrue(ShareSourcePolicy.within("/a/b/c", "/a/b/"))
        assertFalse(ShareSourcePolicy.within("/a/bc", "/a/b"))
    }
}
