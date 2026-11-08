package dev.kore.link

import dev.kore.link.Fixtures.a
import dev.kore.link.Fixtures.b64
import dev.kore.link.Fixtures.s
import dev.kore.link.net.NetControl
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/** control.json: each session message built here encodes to the exact bytes the Mac's encoder gives, and decodes back. */
class ControlFixtureTest {
    private val messages = Fixtures.json("control.json").a("messages").associate { it.s("name") to it.s("json") }
    private val manifest = Fixtures.json("manifest.json")
    private val bind = Fixtures.json("bind.json")

    private fun f(name: String) = Json.parseToJsonElement(messages.getValue(name)) as JsonObject
    private fun JsonObject.l(k: String) = (this[k] as JsonPrimitive).content.toLong()

    @Test fun manifestNamesThisVersionAndPort() {
        val proto = manifest["proto"] as JsonObject
        assertEquals(NetControl.VERSION.toString(), (proto["major"] as JsonPrimitive).content)
        assertEquals(dev.kore.link.net.Tailnet.PORT.toString(), (manifest["port"] as JsonPrimitive).content)
    }

    @Test fun everyMessageEncodesByteForByte() {
        val c = f("challenge")
        val built = mapOf(
            "challenge" to NetControl.Challenge(c.s("route"), UUID.fromString(c.s("device")), b64(c.s("nonce"))),
            "hello" to f("hello").let { h -> NetControl.Hello(h.s("service"), UUID.fromString(h.s("device")), b64(h.s("nonce")), b64(h.s("sig")), h.l("credit")) },
            "hello.ticket" to f("hello.ticket").let { h ->
                NetControl.Hello(h.s("service"), UUID.fromString(h.s("device")), b64(h.s("nonce")), b64(h.s("sig")), h.l("credit"), ticket = b64(h.s("ticket")))
            },
            "welcome" to f("welcome").let { w -> NetControl.Welcome(b64(w.s("sig")), w.l("credit"), b64(w.s("ticket")), true, listOf("read", "ask", "run")) },
            "resume" to NetControl.Resume(f("resume")["cursors"] as JsonObject),
            "credit" to NetControl.Credit(65536),
            "bye" to NetControl.Bye("revoked"),
        )
        assertEquals(messages.keys, built.keys)
        for ((name, message) in built) {
            assertEquals(name, messages.getValue(name), message.encoded().decodeToString())
            assertEquals(name, messages.getValue(name), NetControl.decode(messages.getValue(name).toByteArray()).encoded().decodeToString())
        }
    }

    @Test fun helloCarriesTheFixtureSignatureOverB() {
        assertEquals(bind.s("nonceC"), b64(f("hello").s("nonce")).joinToString("") { "%02x".format(it) })
        assertEquals((bind["tailnet"] as JsonObject).s("sigC"), f("hello").s("sig"))
    }

    @Test fun malformedControlIsRefused() {
        for (bad in listOf("{}", "{\"t\":\"credit\",\"n\":0}", "{\"t\":\"nope\"}", "[1]", "{\"t\":\"bye\"}")) {
            assertEquals(bad, true, runCatching { NetControl.decode(bad.toByteArray()) }.isFailure)
        }
    }

    @Test fun pingAndPongAreKoreNetControlMessages() {
        // As the Mac's sorted-keys encoder writes them (NetControl.ping / .pong).
        assertEquals("""{"n":3,"t":"ping"}""", NetControl.Ping(3).encoded().decodeToString())
        assertEquals("""{"n":3,"t":"pong"}""", NetControl.Pong(3).encoded().decodeToString())
        assertEquals(NetControl.Pong(7), NetControl.decode("""{"t":"pong","n":7}""".toByteArray()))
    }
}
