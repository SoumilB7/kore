package dev.kore.phone

import dev.kore.phone.ui.FolderBrowser
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A box's folder browser in the ＋ sheet: home first, one level at a time, up stops at home, a new folder, refusals. */
class FolderBrowserTest {
    private fun o(s: String): JsonObject = Json.parseToJsonElement(s).jsonObject
    private fun listing(path: String, vararg names: String, more: Boolean = false) = o(
        """{"t":"result","id":"x","ok":true,"path":"$path","more":$more,"entries":[${names.joinToString(",") { """{"name":"$it","kind":"dir"}""" }}]}""",
    )

    @Test fun startsAtTheHomeTheBoxNames() {
        val b = FolderBrowser()
        assertFalse(b.started)
        assertTrue(b.go(null))
        assertEquals("", b.reading)
        assertTrue(b.started)
        // The box answers with the folders only a phone sees, and names the home.
        b.listed(null, o("""{"ok":true,"path":"/home/u","entries":[{"name":"Code","kind":"dir"},{"name":"notes.txt","kind":"file","size":3},
            {"name":"app","kind":"link","dir":true},{"name":"dead","kind":"link"}]}"""))
        assertEquals("/home/u", b.home)
        assertEquals("/home/u", b.path)
        assertNull(b.reading)
        assertEquals(listOf("Code", "app"), b.folders)
        assertFalse(b.canGoUp)
        assertNull(b.up())
        assertEquals("~", FolderBrowser.shown(b.path!!, b.home))
    }

    @Test fun intoAndUpOneLevelAtATimeKeptFoldersShowAtOnce() {
        val b = FolderBrowser()
        b.go(null)
        b.listed(null, listing("/home/u", "Code", "notes"))
        val code = b.into("Code")!!
        assertEquals("/home/u/Code", code)
        assertTrue(b.go(code))
        assertEquals(code, b.reading)
        // Still showing the home until the answer.
        assertEquals("/home/u", b.path)
        b.listed(code, listing(code, "Platform", "Onfinance", more = true))
        assertEquals(code, b.path)
        assertEquals(listOf("Platform", "Onfinance"), b.folders)
        assertTrue(b.more)
        assertEquals("~/Code", FolderBrowser.shown(code, b.home))
        assertTrue(b.canGoUp)
        assertEquals("/home/u", b.up())
        // The home was read: back at once, no ask.
        assertFalse(b.go(b.up()))
        assertEquals("/home/u", b.path)
        assertFalse(b.go(code))
        assertEquals(listOf("Platform", "Onfinance"), b.folders)
    }

    @Test fun aLateAnswerForAFolderLeftIsKeptNotShown() {
        val b = FolderBrowser()
        b.go(null)
        b.listed(null, listing("/home/u", "a", "b"))
        b.go("/home/u/a")
        b.go("/home/u/b")
        b.listed("/home/u/a", listing("/home/u/a", "x"))
        assertEquals("/home/u", b.path)
        assertEquals("/home/u/b", b.reading)
        b.listed("/home/u/b", listing("/home/u/b", "y"))
        assertEquals(listOf("y"), b.folders)
        assertFalse(b.go("/home/u/a"))
        assertEquals(listOf("x"), b.folders)
    }

    @Test fun aNewFolderIsListedInOrderAndEnteredEmpty() {
        val b = FolderBrowser()
        b.go(null)
        b.listed(null, listing("/home/u", "alpha", "Zed"))
        b.made("mid")
        assertEquals("/home/u/mid", b.path)
        assertEquals(emptyList<String>(), b.folders)
        assertFalse(b.go("/home/u"))
        assertEquals(listOf("alpha", "mid", "Zed"), b.folders)
    }

    @Test fun namesAreCheckedBeforeTheBoxIsAsked() {
        val here = listOf("Code")
        assertEquals("Name the folder.", FolderBrowser.nameProblem("  ", here))
        assertEquals("One name, no slashes.", FolderBrowser.nameProblem("a/b", here))
        assertEquals("Not a hidden folder.", FolderBrowser.nameProblem(".ssh", here))
        assertEquals("Code is already there.", FolderBrowser.nameProblem("Code", here))
        assertEquals("Too long.", FolderBrowser.nameProblem("é".repeat(128), here))
        assertNull(FolderBrowser.nameProblem("new app", here))
    }

    @Test fun refusalsSayTheBoxsWordsAndAnOlderBoxFallsBack() {
        val b = FolderBrowser()
        b.go(null)
        b.listed(null, listing("/home/u", "Code"))
        b.go("/home/u/Code")
        b.listed("/home/u/Code", o("""{"ok":false,"code":"denied.path","message":"A link out of the folder, not followed."}"""))
        assertEquals("A link out of the folder, not followed.", b.problem)
        assertEquals("/home/u", b.path)
        assertFalse(b.unsupported)
        // The next move clears it.
        b.go("/home/u/Code")
        assertNull(b.problem)
        val old = FolderBrowser()
        old.go(null)
        old.listed(null, o("""{"ok":false,"code":"denied.control","message":"That needs a grant with full control."}"""))
        assertTrue(old.unsupported)
        assertNull(old.path)
    }

    @Test fun openHereWaitsWhileAnotherFolderIsRead() {
        val b = FolderBrowser()
        assertFalse(b.canOpen)
        b.go(null)
        b.listed(null, listing("/home/u", "Code"))
        assertTrue(b.canOpen)
        assertTrue(b.go(b.into("Code")))
        // Still showing the home while Code is read: Open here would open the wrong folder.
        assertEquals("/home/u", b.path)
        assertFalse(b.canOpen)
        b.listed("/home/u/Code", listing("/home/u/Code"))
        assertTrue(b.canOpen)
    }

    @Test fun aFailedHomeReadOffersRetryAndStartsClean() {
        val b = FolderBrowser()
        b.go(null)
        assertFalse(b.failedFirst)
        b.listed(null, o("""{"ok":false,"code":"busy","message":"Busy there."}"""))
        assertTrue(b.failedFirst)
        assertFalse(b.unsupported)
        assertFalse(b.canOpen)
        assertNull(b.home)
        // Retry asks for the home again.
        assertTrue(b.go(null))
        assertFalse(b.failedFirst)
        b.listed(null, listing("/home/u", "Code"))
        assertEquals("/home/u", b.path)
        assertFalse(b.failedFirst)
        // A later refusal isn't a failed first read.
        b.go(b.into("Code"))
        b.listed("/home/u/Code", o("""{"ok":false,"code":"denied.path"}"""))
        assertFalse(b.failedFirst)
    }

    @Test fun keepsABoundedNumberOfFolders() {
        val b = FolderBrowser()
        b.go(null)
        b.listed(null, listing("/home/u", "a"))
        for (i in 0..FolderBrowser.KEEP + 4) {
            b.go("/home/u/f$i")
            b.listed("/home/u/f$i", listing("/home/u/f$i"))
        }
        // The home was read longest ago: it's read again.
        assertTrue(b.go("/home/u"))
    }
}
