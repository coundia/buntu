package com.pcoundia.buntu.core.platform

import com.pcoundia.buntu.core.platform.logging.RedactedAppLogger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class RedactedAppLoggerTest {

    @Test
    fun `describeStreamUrl masks credentials and path segments leaving only host and extension`() {
        val sensitive = "http://tv.konfatta.xyz:8080/movie/my_user/super_secret_pw/994821.mkv?token=abc"
        val redacted = RedactedAppLogger.describeStreamUrl(sensitive)

        assertEquals("tv.konfatta.xyz, .mkv", redacted)
        assertFalse(redacted.contains("my_user"))
        assertFalse(redacted.contains("super_secret_pw"))
        assertFalse(redacted.contains("token"))
    }
}

