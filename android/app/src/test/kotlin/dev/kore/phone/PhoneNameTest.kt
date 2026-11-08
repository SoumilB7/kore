package dev.kore.phone

import org.junit.Assert.assertEquals
import org.junit.Test

/** The phone's name for the Mac: its settings' name, else maker and marketing model, else the model code. */
class PhoneNameTest {
    @Test fun theSettingsNameWins() {
        assertEquals("Soumil's Nord", PhoneName.pick("Soumil's Nord", "OnePlus", "Nord CE 2", "CPH2381"))
        assertEquals("OnePlus Nord CE 2", PhoneName.pick(" OnePlus Nord CE 2 ", "OnePlus", null, "CPH2381"))
    }

    @Test fun aNameThatIsOnlyTheModelCodeGivesWayToTheMarketingName() {
        assertEquals("OnePlus Nord CE 2", PhoneName.pick("CPH2381", "OnePlus", "Nord CE 2", "CPH2381"))
        assertEquals("OnePlus Nord CE 2", PhoneName.pick(null, "OnePlus", "Nord CE 2", "CPH2381"))
        // The maker said once.
        assertEquals("OnePlus Nord CE 2", PhoneName.pick("", "oneplus", "OnePlus Nord CE 2", "CPH2381"))
        assertEquals("Xiaomi Redmi Note 12", PhoneName.pick(null, "xiaomi", "Redmi Note 12", "23021RAAEG"))
    }

    @Test fun elseTheModelCodeElseAndroid() {
        assertEquals("CPH2381", PhoneName.pick(null, "OnePlus", null, "CPH2381"))
        assertEquals("CPH2381", PhoneName.pick("  ", "OnePlus", "CPH2381", "CPH2381"))
        assertEquals("Android", PhoneName.pick(null, null, null, null))
    }
}
