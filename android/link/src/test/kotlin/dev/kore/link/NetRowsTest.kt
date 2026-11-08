package dev.kore.link

import dev.kore.link.net.NetRow
import dev.kore.link.net.NetRows
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NetRowsTest {
    private fun row(name: String, vararg addrs: String, default: Boolean = false, up: Boolean = true, loopback: Boolean = false) =
        NetRow(name, 1, 1500, up, loopback, false, false, addrs.toList(), default, "")

    @Test fun connectivityManagersListWinsAsItIs() {
        val all = listOf(row("wlan0", "192.168.1.5/24", default = true), row("rmnet0", "10.0.0.2/30"))
        assertEquals(all, NetRows.pick(all, { error("not asked") }, { error("not asked") }))
    }

    @Test fun noneListedTakesTheActiveNetworkAsDefault() {
        assertEquals(listOf(row("wlan0", "192.168.1.5/24", default = true)), NetRows.pick(emptyList(), { row("wlan0", "192.168.1.5/24") }, { error("not asked") }))
    }

    @Test fun noneAtAllFallsBackToJavaNetsListWithAnIpv4Default() {
        val java = listOf(row("lo", "127.0.0.1/8", loopback = true), row("dummy0"), row("v6only", "2001:db8::1/64"), row("rmnet_data0", "10.1.2.3/30"), row("down0", "10.9.9.9/24", up = false))
        val got = NetRows.pick(emptyList(), { null }, { java })
        assertEquals(listOf("v6only", "rmnet_data0"), got.map { it.name })
        assertEquals(listOf(false, true), got.map { it.default })
    }

    @Test fun offlineIsEmpty() = assertTrue(NetRows.pick(emptyList(), { null }, { emptyList() }).isEmpty())
}
