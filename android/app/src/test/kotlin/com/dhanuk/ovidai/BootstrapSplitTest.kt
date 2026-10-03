package com.dhanuk.ovidai

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class BootstrapSplitTest {
    @get:Rule val temp = TemporaryFolder()

    private fun apk(name: String, vararg abis: String): String {
        val file = temp.newFile(name)
        ZipOutputStream(file.outputStream()).use { zip ->
            for (abi in abis) {
                zip.putNextEntry(ZipEntry("lib/$abi/libovid_bootstrap.so"))
                zip.write("payload-$abi".toByteArray())
                zip.closeEntry()
            }
        }
        return file.path
    }

    @Test fun searchesBaseAndAllSplitsForExactProcessAbi() {
        val base = apk("base.apk", "arm64-v8a")
        val language = apk("config.en.apk")
        val arm = apk("config.armeabi_v7a.apk", "armeabi-v7a")
        val payload = readInstalledBootstrap(base, arrayOf(language, arm), "armeabi-v7a")
        assertEquals("armeabi-v7a", payload.abi)
        assertArrayEquals("payload-armeabi-v7a".toByteArray(), payload.bytes)
    }

    @Test fun baseOnlyInstallAndLegacyArmAliasRemainReadable() {
        val payload = readInstalledBootstrap(apk("base.apk", "armeabi-v7a"), null, "armeabi")
        assertEquals("armeabi-v7a", payload.abi)
    }

    @Test fun missingOrUnknownProcessAbiNeverFallsBackToAnotherArchitecture() {
        val base = apk("base.apk", "arm64-v8a")
        val split = apk("split.apk", "x86_64")
        for (process in listOf("armeabi-v7a", "x86", null)) {
            val payload = readInstalledBootstrap(base, arrayOf(split), process)
            assertNull(payload.bytes)
            assertNull(payload.abi)
            assertEquals(listOf("arm64-v8a", "x86_64"), payload.availableAbis)
        }
    }

    @Test fun corruptSplitReadFailsRatherThanReturningIncompatibleBasePayload() {
        val bad = temp.newFile("broken.apk").apply { writeText("not a zip") }
        try {
            readInstalledBootstrap(apk("base.apk", "arm64-v8a"), arrayOf(bad.path), "x86_64")
            fail("Corrupt split must be reported as a read failure")
        } catch (_: java.io.IOException) { }
        // A subsequent valid install can still be read after the failure.
        val result = readInstalledBootstrap(apk("valid.apk", "x86_64"), null, "x86_64")
        assertArrayEquals("payload-x86_64".toByteArray(), result.bytes)
    }
}
