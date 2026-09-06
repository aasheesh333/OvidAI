package com.dhanuk.ovidai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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

    @Test
    fun successfulReadWithoutALaterEventBecomesClean() {
        val generation = TreeReadGeneration()
        val startedAt = generation.beginRead(forceFull = false)

        generation.completeRead(checkNotNull(startedAt))

        assertNull(generation.beginRead(forceFull = false))
    }

    @Test
    fun eventDuringReadStillForcesTheNextRead() {
        val generation = TreeReadGeneration()
        val startedAt = checkNotNull(generation.beginRead(forceFull = false))

        val laterEvent = generation.markDirty()
        generation.completeRead(startedAt)

        assertTrue(laterEvent > startedAt)
        assertEquals(laterEvent, generation.beginRead(forceFull = false))
    }

    @Test
    fun unavailableRootPreservesDirtyGenerationForRetry() {
        val generation = TreeReadGeneration()
        val startedAt = checkNotNull(generation.beginRead(forceFull = false))

        generation.abandonRead(startedAt)

        val retryGeneration = checkNotNull(generation.beginRead(forceFull = false))
        assertTrue(retryGeneration > startedAt)
    }

    @Test
    fun forcedReadStartsEvenWhenGenerationIsClean() {
        val generation = TreeReadGeneration()
        val startedAt = checkNotNull(generation.beginRead(forceFull = false))
        generation.completeRead(startedAt)

        assertEquals(startedAt, generation.beginRead(forceFull = true))
    }

    @Test
    fun unavailableRootTransitionPreservesCachedTreeAndLeavesReadPending() {
        val cache = TreeReadCache<String>()
        val initialRead = checkNotNull(cache.beginRead(forceFull = false))
        val cachedRow = mapOf<String, Any?>("handle" to 17, "text" to "Send")
        cache.commit(
            readGeneration = initialRead,
            packageName = "com.example.notes",
            windowId = 42,
            rows = linkedMapOf("send-key" to cachedRow),
            nodes = mutableMapOf(17 to "retained-node"),
            handles = mutableMapOf("send-key" to 17),
            newNextHandle = 18,
            forceFull = true,
        )
        cache.markDirty()
        val unavailableRead = checkNotNull(cache.beginRead(forceFull = false))

        val unavailable = cache.unavailable(unavailableRead)

        assertEquals("unavailable", unavailable.status)
        assertEquals("com.example.notes", unavailable.packageName)
        assertEquals(42, unavailable.windowId)
        assertEquals(linkedMapOf("send-key" to cachedRow), cache.rows)
        assertEquals(mapOf(17 to "retained-node"), cache.nodesByHandle)
        assertEquals(mapOf("send-key" to 17), cache.handlesByStableKey)
        assertEquals(18, cache.nextHandle)
        assertNotNull(cache.beginRead(forceFull = false))
    }
}
