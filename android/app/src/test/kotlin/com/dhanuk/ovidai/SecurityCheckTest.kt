package com.dhanuk.ovidai

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class SecurityCheckTest {

    @Test
    fun securityCheckSmokeTest() {
        // Basic execution test to ensure SecurityCheck doesn't crash on standard environments
        assertNotNull(SecurityCheck.isDebuggerAttached())
        assertNotNull(SecurityCheck.isRooted())
    }
}
