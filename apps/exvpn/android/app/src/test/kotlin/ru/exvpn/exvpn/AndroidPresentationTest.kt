package ru.exvpn.exvpn

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidPresentationTest {
    @Test fun phoneAndLandscapeTabletDoNotBecomeTv() {
        assertFalse(AndroidPresentation.isTelevision(0x11, false, false))
        assertFalse(AndroidPresentation.isTelevision(0x21, false, false))
    }
    @Test fun televisionUiModeWorksInBothThemes() {
        assertTrue(AndroidPresentation.isTelevision(0x14, false, false))
        assertTrue(AndroidPresentation.isTelevision(0x24, false, false))
    }
    @Test fun tvAndLeanbackDeviceFeaturesWork() {
        assertTrue(AndroidPresentation.isTelevision(0x11, true, false))
        assertTrue(AndroidPresentation.isTelevision(0x11, false, true))
    }
}
