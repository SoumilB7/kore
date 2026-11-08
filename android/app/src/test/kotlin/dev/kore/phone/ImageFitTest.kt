package dev.kore.phone

import dev.kore.phone.ui.ImageActivity
import org.junit.Assert.assertEquals
import org.junit.Test

/** The viewer decodes at the screen's size: the longer edge down to it, never up, the shape kept. */
class ImageFitTest {
    @Test fun aLargePhotoComesDownToTheScreen() {
        assertEquals(2400 to 1800, ImageActivity.fit(4032, 3024, 2400))
        assertEquals(1080 to 2400, ImageActivity.fit(1440, 3200, 2400))
    }

    @Test fun aSmallOneStaysAsItIs() {
        assertEquals(96 to 64, ImageActivity.fit(96, 64, 2400))
        assertEquals(2400 to 10, ImageActivity.fit(2400, 10, 2400))
    }

    @Test fun aSliverKeepsAPixel() {
        assertEquals(2400 to 1, ImageActivity.fit(100_000, 2, 2400))
        assertEquals(0 to 0, ImageActivity.fit(0, 0, 2400))
    }
}
