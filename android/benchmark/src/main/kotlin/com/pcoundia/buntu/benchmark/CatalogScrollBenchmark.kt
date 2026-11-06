package com.pcoundia.buntu.benchmark

import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * PRD-37 § 5.1 & § 13:
 * Measures 60 fps frame timing (< 2% janky frames > 16 ms) while scrolling catalog shelves & lists.
 */
@RunWith(AndroidJUnit4::class)
class CatalogScrollBenchmark {

    @get:Rule
    val benchmarkRule = MacrobenchmarkRule()

    @Test
    fun scrollLiveAndCatalogFrames() = benchmarkRule.measureRepeated(
        packageName = "com.pcoundia.buntu",
        metrics = listOf(FrameTimingMetric()),
        iterations = 5,
        startupMode = StartupMode.WARM,
        compilationMode = CompilationMode.Partial(),
    ) {
        startActivityAndWait()
        device.waitForIdle()
        val displayW = device.displayWidth
        val displayH = device.displayHeight
        device.swipe(displayW / 2, (displayH * 3) / 4, displayW / 2, displayH / 4, 20)
        device.wait(Until.gone(androidx.test.uiautomator.By.text("__nonexistent__")), 250)
        val root = device.findObject(androidx.test.uiautomator.By.pkg("com.pcoundia.buntu"))
        root?.fling(Direction.DOWN)
    }
}

