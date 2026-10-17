package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test

class ApplicationOwnerConfirmationTest {
    private val selected = setOf("sample.selected")
    private val selectedUIDs = setOf(10168)
    private fun owner(uid: Int, packages: Set<String>, mode: String = "include",
        selection: Set<String> = selected, resolved: Set<Int> = selectedUIDs) =
        ApplicationOwnerConfirmation.confirm(uid, 10100, packages, mode, selection, resolved)

    @Test fun includeConfirmsKnownUnselectedTupleInsteadOfTurningItIntoUnknown() {
        assertEquals(10167, owner(10167, setOf("sample.unselected")))
        assertEquals(10168, owner(10168, selected))
        assertEquals(10167, owner(10167, setOf("sample.unselected"), selection = emptySet(), resolved = emptySet()))
    }

    @Test fun excludeAndDisabledRetainTheirExistingOwnerBoundary() {
        assertEquals(-1, owner(10167, setOf("sample.unselected"), "exclude"))
        assertEquals(10168, owner(10168, selected, "exclude"))
        assertEquals(-1, owner(10167, setOf("sample.unselected"), "disabled"))
        assertEquals(-1, owner(10168, selected, "disabled"))
    }

    @Test fun unknownSystemAndVpnOwnersNeverGainDirectPermission() {
        for (uid in listOf(-1, 0, 1000, 9999, 10100)) {
            assertEquals(-1, owner(uid, setOf("sample.unselected")))
        }
        assertEquals(-1, owner(10167, emptySet()))
        assertEquals(-1, owner(10168, emptySet()))
        assertEquals(-1, owner(10167, setOf("sample.unselected"), "invalid"))
    }

    @Test fun sharedUidMustBeEntirelySelectedOrEntirelyUnselected() {
        val shared = setOf("sample.selected", "sample.shared")
        assertEquals(-1, owner(10168, shared))
        assertEquals(-1, owner(10168, shared, "exclude"))
        assertEquals(10168, owner(10168, shared, selection = shared))
        assertEquals(10167, owner(10167, setOf("sample.first", "sample.second")))
        assertEquals(-1, owner(10167, shared))
    }

    @Test fun uidChangesAndReuseRequireAFreshSelectionSnapshot() {
        assertEquals(-1, owner(10169, selected))
        assertEquals(-1, owner(10168, setOf("sample.replacement")))
        assertEquals(10169, owner(10169, selected, resolved = setOf(10169)))
    }

    @Test fun secondaryProfileSystemSandboxAndIsolatedUidsStayUnknown() {
        for (appId in listOf(0, 1000, 9999, 20000, 29999, 90000, 99000, 99999)) {
            for (userId in listOf(0, 10)) {
                val uid = userId * 100000 + appId
                assertFalse(ApplicationOwnerConfirmation.isApplicationUID(uid))
                assertEquals(-1, ApplicationOwnerConfirmation.confirm(uid, 1010100,
                    setOf("sample.unselected"), "include", emptySet(), emptySet()))
            }
        }
    }

    @Test fun secondaryProfileApplicationsUseFullUidAndRejectTheVpnItself() {
        for (appId in listOf(10000, 10167, 19999)) {
            val uid = 1000000 + appId
            assertTrue(ApplicationOwnerConfirmation.isApplicationUID(uid))
            assertEquals(uid, ApplicationOwnerConfirmation.confirm(uid, 1010100,
                setOf("sample.unselected"), "include", emptySet(), emptySet()))
        }
        assertEquals(-1, ApplicationOwnerConfirmation.confirm(1010100, 1010100,
            setOf("sample.vpn"), "include", emptySet(), emptySet()))
        assertEquals(1010168, ApplicationOwnerConfirmation.confirm(1010168, 1010100,
            selected, "include", selected, setOf(1010168)))
    }
}
