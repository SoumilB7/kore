package dev.kore.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** The phone's tailnet name: one per install, so Tailscale never has to add "-1" (T-A8, the node pile-up). */
class HostnameTest {
    @Test fun modelAndFourHexOfTheInstall() {
        assertEquals("kore-cph2381-7f3a", Mesh.hostnameFor("CPH2381", "7F3A91C2-0000-4000-8000-000000000000"))
        assertEquals("kore-pixel-9-pro-0b1c", Mesh.hostnameFor("Pixel 9 Pro", "0b1c-ffff"))
        assertEquals("kore-phone-abcd", Mesh.hostnameFor(null, "abcd1234"))
    }

    @Test fun twoPhonesOfOneModelNeverShareAName() {
        assertNotEquals(Mesh.hostnameFor("Pixel 9", "1111aaaa"), Mesh.hostnameFor("Pixel 9", "2222bbbb"))
    }

    @Test fun aLongModelStaysWithinADnsLabel() {
        val name = Mesh.hostnameFor("x".repeat(80), "abcd")
        assert(name.length <= 63) { name }
    }
}
