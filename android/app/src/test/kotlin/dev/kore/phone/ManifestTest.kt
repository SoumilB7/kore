package dev.kore.phone

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * The manifest as Android 14+ checks it at startForeground: every foreground service's type has
 * its FOREGROUND_SERVICE_<TYPE> permission and one of that type's prerequisites declared (else a
 * SecurityException). Read straight from the XML: no Robolectric.
 */
class ManifestTest {
    private val ns = "http://schemas.android.com/apk/res/android"
    private val root: Element = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder()
        .parse(listOf(File("src/main/AndroidManifest.xml"), File("app/src/main/AndroidManifest.xml")).first { it.exists() }).documentElement

    private fun elements(tag: String): List<Element> = root.getElementsByTagName(tag).let { l -> (0 until l.length).map { l.item(it) as Element } }
    private val permissions = elements("uses-permission").map { it.getAttributeNS(ns, "name") }.toSet()

    /** Android 14's rule per type (developer.android.com, foreground service types): a manifest permission it accepts without a prompt. */
    private val prerequisites = mapOf(
        "connectedDevice" to setOf("android.permission.CHANGE_NETWORK_STATE", "android.permission.CHANGE_WIFI_STATE", "android.permission.CHANGE_WIFI_MULTICAST_STATE", "android.permission.NFC", "android.permission.TRANSMIT_IR"),
    )

    @Test fun everyForegroundServiceHasItsTypePermissionAndAPrerequisite() {
        val services = elements("service").filter { it.hasAttributeNS(ns, "foregroundServiceType") }
        assertEquals(setOf(".background.SignInService"), services.map { it.getAttributeNS(ns, "name") }.toSet())
        assertTrue("android.permission.FOREGROUND_SERVICE" in permissions)
        for (s in services) {
            val name = s.getAttributeNS(ns, "name")
            for (type in s.getAttributeNS(ns, "foregroundServiceType").split('|')) {
                val upper = type.replace(Regex("([A-Z])"), "_$1").uppercase()
                assertTrue("$name: FOREGROUND_SERVICE_$upper", "android.permission.FOREGROUND_SERVICE_$upper" in permissions)
                val pre = prerequisites[type] ?: error("$name: $type has no checked prerequisite here")
                assertTrue("$name: $type needs one of $pre", pre.any { it in permissions })
                assertEquals("$name stays private", "false", s.getAttributeNS(ns, "exported"))
            }
        }
    }

    @Test fun theServicesStartForegroundWithTheTypeTheManifestDeclares() {
        // startForeground(…, type) must name a type the manifest declares for that service.
        val src = File(listOf("src/main/kotlin", "app/src/main/kotlin").first { File(it).exists() }, "dev/kore/phone/background")
        for (f in listOf("SignInService.kt")) {
            val text = File(src, f).readText()
            assertTrue(f, "FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE" in text)
            assertTrue("$f catches a refused startForeground", Regex("try \\{\\s*startForeground").containsMatchIn(text))
        }
    }

    @Test fun noPermissionThatPromptsOrNeedsPlayReview() {
        val prompting = setOf("android.permission.BLUETOOTH_CONNECT", "android.permission.ACCESS_FINE_LOCATION", "android.permission.FOREGROUND_SERVICE_SPECIAL_USE", "android.permission.FOREGROUND_SERVICE_DATA_SYNC")
        assertTrue((permissions intersect prompting).toString(), (permissions intersect prompting).isEmpty())
    }
}
