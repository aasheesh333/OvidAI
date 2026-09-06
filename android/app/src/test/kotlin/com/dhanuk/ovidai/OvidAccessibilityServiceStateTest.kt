package com.dhanuk.ovidai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OvidAccessibilityServiceStateTest {
    @Test
    fun stableKeyIncludesEveryIdentityField() {
        assertEquals(
            "app:id/send|android.widget.Button|Send|Send message|1,2,30,40",
            stableNodeKey(
                viewId = "app:id/send",
                className = "android.widget.Button",
                text = "Send",
                description = "Send message",
                bounds = listOf(1, 2, 30, 40),
            ),
        )
    }

    @Test
    fun stableHandleReusesExistingValueAndAdvancesOnlyForNewKeys() {
        val existing = mapOf("same" to 17)

        assertEquals(HandleAllocation(17, 23), allocateStableHandle(existing, "same", 23))
        assertEquals(HandleAllocation(23, 24), allocateStableHandle(existing, "new", 23))
    }

    @Test
    fun deltaReportsAddedChangedAndRemovedRows() {
        val previous = linkedMapOf<String, Map<String, Any?>>(
            "same" to mapOf("handle" to 3, "focused" to false),
            "gone" to mapOf("handle" to 7, "text" to "old"),
        )
        val current = linkedMapOf<String, Map<String, Any?>>(
            "same" to mapOf("handle" to 3, "focused" to true),
            "new" to mapOf("handle" to 8, "text" to "new"),
        )

        val delta = diffNodeRows(previous, current, forceFull = false, windowChanged = false)

        assertFalse(delta.full)
        assertEquals(listOf(current.getValue("new")), delta.added)
        assertEquals(listOf(current.getValue("same")), delta.changed)
        assertEquals(listOf(7), delta.removed)
    }

    @Test
    fun forcedOrChangedWindowReturnsAFullTree() {
        val previous = linkedMapOf<String, Map<String, Any?>>(
            "old" to mapOf("handle" to 1),
        )
        val current = linkedMapOf<String, Map<String, Any?>>(
            "new" to mapOf("handle" to 2),
        )

        for (delta in listOf(
            diffNodeRows(previous, current, forceFull = true, windowChanged = false),
            diffNodeRows(previous, current, forceFull = false, windowChanged = true),
        )) {
            assertTrue(delta.full)
            assertEquals(listOf(current.getValue("new")), delta.added)
            assertTrue(delta.changed.isEmpty())
            assertTrue(delta.removed.isEmpty())
        }
    }
}
