package com.dhanuk.ovidai

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Selection rule for the browser geolocation bridge.
 *
 * Only [GeoFix.newestIndex] is covered here: [GeoFix.read] needs a Context and a
 * LocationManager, neither of which exists on a unit-test JVM (this module has no
 * Robolectric). The selection rule is the part worth pinning anyway — picking the
 * OLDEST cached fix would silently serve a stale position to a login flow that is
 * checking "is this device where the user says it is", and every provider can
 * legitimately be missing (no SIM, no Google Play services, location switched
 * off), so the "nothing usable" answer matters just as much.
 *
 * NOTE: `flutter test` does not run these; they execute under
 * `./gradlew :app:testDebugUnitTest`. The Dart-side contract for the same feature
 * is pinned in test/browser_geolocation_test.dart, which CI does run.
 */
class GeoFixTest {

    @Test
    fun picksTheNewestFixNotTheFirstProviderThatAnswered() {
        // Provider order is a PREFERENCE, not a freshness ranking: gps is asked
        // first, but here it holds the stalest reading and must lose.
        val times = listOf(1_000L, 3_000L, 2_000L)
        assertEquals(1, GeoFix.newestIndex(times))
    }

    @Test
    fun skipsProvidersThatHadNoFix() {
        assertEquals(2, GeoFix.newestIndex(listOf(null, null, 5L, 4L)))
    }

    @Test
    fun allMissingMeansNoUsableFix() {
        // -1 is what makes read() answer "no fix" (W3C code 2) instead of
        // crashing on an index, or worse, serving a null position as 0,0 —
        // which is a real place in the Gulf of Guinea and a classic bug.
        assertEquals(-1, GeoFix.newestIndex(listOf(null, null, null)))
        assertEquals(-1, GeoFix.newestIndex(emptyList()))
    }

    @Test
    fun equalTimestampsKeepThePreferredProvider() {
        // Two providers stamped the same millisecond. The pick must stay
        // deterministic so a flapping result cannot make a page's position jump
        // between readings of different accuracy.
        assertEquals(0, GeoFix.newestIndex(listOf(7L, 7L, 7L)))
    }

    @Test
    fun aSingleFixIsPickedWhateverItsValue() {
        assertEquals(0, GeoFix.newestIndex(listOf(0L)))
        assertEquals(0, GeoFix.newestIndex(listOf(null, 1L)))
    }
}
