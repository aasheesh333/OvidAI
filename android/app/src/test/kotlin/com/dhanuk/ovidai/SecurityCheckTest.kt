package com.dhanuk.ovidai

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test

class SecurityCheckTest {

    @Test
    fun securityCheckSmokeTest() {
        // Basic execution test to ensure SecurityCheck doesn't crash on standard environments
        assertNotNull(SecurityCheck.isDebuggerAttached())
        assertNotNull(SecurityCheck.isRooted())
    }
}
