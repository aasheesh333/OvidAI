package com.dhanuk.ovidai

import android.content.pm.PackageManager
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [23, 24, 26])
class NativeTelemetryDefaultsTest {
    @Test fun mergedManifestDisablesCollectionBeforeDartRestoresConsent() {
        val app = RuntimeEnvironment.getApplication()
        val metadata = app.packageManager.getApplicationInfo(
            app.packageName, PackageManager.GET_META_DATA
        ).metaData
        // Firebase defaults to collection enabled when these keys are absent.
        assertEquals(false, metadata.get("firebase_analytics_collection_enabled"))
        assertEquals(false, metadata.get("firebase_crashlytics_collection_enabled"))
        // Permanent deactivation would prevent the existing consent controls
        // from enabling analytics after the user opts in.
        assertFalse(metadata.getBoolean("firebase_analytics_collection_deactivated", false))
    }
}
