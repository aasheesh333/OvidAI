package com.dhanuk.ovidai

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class PasswordTreeRedactionTest {
    @Test fun passwordTextAndDescriptionNeverEnterFullOrCachedChannelRows() {
        val service = Robolectric.buildService(OvidAccessibilityService::class.java).create().get()
        val node = AccessibilityNodeInfo.obtain().apply {
            packageName = "example.login"
            className = "android.widget.EditText"
            isVisibleToUser = true
            isPassword = true
            text = "secret-text"
            contentDescription = "secret-description"
            setBoundsInScreen(Rect(0, 0, 100, 50))
        }
        val window = AccessibilityWindowInfo.obtain()
        shadowOf(window).setType(AccessibilityWindowInfo.TYPE_APPLICATION)
        shadowOf(window).setFocused(true)
        shadowOf(window).setRoot(node)
        shadowOf(service).setWindows(listOf(window))
        try {
            val full = service.readScreen(true)
            assertEquals("ok", full["status"])
            val rows = full["nodes"] as? List<*> ?: full["added"] as List<*>
            val row = rows.single() as Map<*, *>
            assertEquals(true, row["password"])
            assertEquals("", row["text"])
            assertEquals("", row["description"])
            assertFalse(full.toString().contains("secret-"))
            assertFalse(service.readScreen(false).toString().contains("secret-"))
        } finally {
            service.onDestroy()
        }
    }
}
