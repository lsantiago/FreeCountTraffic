package com.freecount.traffic

import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import com.freecount.traffic.ml.VehicleDetector
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.io.FileOutputStream

class SmokeTest {
    @get:Rule
    val rule = createAndroidComposeRule<MainActivity>()

    private fun screenshot(name: String) {
        val inst = InstrumentationRegistry.getInstrumentation()
        val dir = File(inst.targetContext.getExternalFilesDir(null), "screenshots").apply { mkdirs() }
        val bmp = inst.uiAutomation.takeScreenshot() ?: return
        FileOutputStream(File(dir, "$name.png")).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    /** Native MediaPipe/TFLite libraries load and the bundled model runs on this ABI. */
    @Test
    fun detectorLoadsAndRuns() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        VehicleDetector(ctx).use { d ->
            val frame = Bitmap.createBitmap(640, 360, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.GRAY) }
            assertTrue(d.detect(frame).isEmpty())
        }
    }

    @Test
    fun homeShowsSourcesAndHistoryOpens() {
        rule.onNodeWithText("Camera").assertIsDisplayed()
        rule.onNodeWithText("Video file").assertIsDisplayed()
        rule.onNodeWithText("RTSP stream").assertIsDisplayed()
        screenshot("01_home")
        rule.onNodeWithText("History").performClick()
        rule.onNodeWithText("No sessions yet.").assertIsDisplayed()
        screenshot("02_history")
    }

    @Test
    fun videoScreenShowsZoneEditor() {
        rule.onNodeWithText("Video file").performClick()
        rule.onNodeWithText("Choose video…").assertIsDisplayed()
        rule.onNodeWithText("Zones").assertIsDisplayed()
        screenshot("03_video_screen")
    }

    @Test
    fun rtspScreenValidatesUrl() {
        rule.onNodeWithText("RTSP stream").performClick()
        rule.onNodeWithText("Connect").performClick()
        rule.onNodeWithText("URL must start with rtsp://").assertIsDisplayed()
        screenshot("04_rtsp_screen")
    }
}
